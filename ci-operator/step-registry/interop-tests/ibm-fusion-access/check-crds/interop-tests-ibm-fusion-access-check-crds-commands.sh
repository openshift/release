#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_check_crds_tests.xml"
TEST_START_TIME=$SECONDS
TESTS_TOTAL=0
TESTS_FAILED=0
TESTS_PASSED=0
TEST_CASES=""

# Function to add test result to JUnit XML
add_test_result() {
  local test_name="$1"
  local test_status="$2"  # "passed" or "failed"
  local test_duration="$3"
  local test_message="${4:-}"
  local test_classname="${5:-CheckCRDsTests}"
  
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  
  if [[ "$test_status" == "passed" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${test_name}\" classname=\"${test_classname}\" time=\"${test_duration}\"/>"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${test_name}\" classname=\"${test_classname}\" time=\"${test_duration}\">
      <failure message=\"Test failed\">${test_message}</failure>
    </testcase>"
  fi
}

function installYQIfNotExists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
         -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    fi
}

function mapTestsForComponentReadiness() {
    [[ ${MAP_TESTS:-false} != "true" ]] && return

    results_file="${1}"
    echo "Patching Tests Result File: ${results_file}"
    if [ -f "${results_file}" ]; then
        installYQIfNotExists
        export REPORTPORTAL_CMP
        echo "Mapping Test Suite Name To: ${REPORTPORTAL_CMP}"
        yq eval -px -ox -iI0 '.testsuites.testsuite.+@name=env(REPORTPORTAL_CMP)' $results_file
    fi
    true
}

# Function to generate JUnit XML report
generate_junit_xml() {
  local total_duration=$((SECONDS - TEST_START_TIME))
  
  cat > "${JUNIT_RESULTS_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Check CRDs Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
${TEST_CASES}
  </testsuite>
</testsuites>
EOF
  
  echo ""
  echo "📊 Test Results Summary:"
  echo "  Total Tests: ${TESTS_TOTAL}"
  echo "  Passed: ${TESTS_PASSED}"
  echo "  Failed: ${TESTS_FAILED}"
  echo "  Duration: ${total_duration}s"
  echo "  Results File: ${JUNIT_RESULTS_FILE}"
  
  mapTestsForComponentReadiness "${JUNIT_RESULTS_FILE}"

  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/$(basename ${JUNIT_RESULTS_FILE})"
    echo "  ✅ Results copied to SHARED_DIR"
  fi
}

# Trap to ensure JUnit XML is generated even on failure
trap generate_junit_xml EXIT

echo "🔍 Waiting for IBM Storage Scale CRDs..."

# Test 1: Wait for CRDs to be established
test_start=$SECONDS
test_status="failed"
test_message=""

# The FusionAccess operator installs the IBM Storage Scale operator which creates these CRDs
if oc wait --for=condition=Established crd/clusters.scale.spectrum.ibm.com --timeout=600s; then
  echo "✅ IBM Storage Scale CRDs are ready"
  test_status="passed"
else
  echo "❌ CRDs not established within timeout"
  test_message="CRDs not established within 600s timeout"
fi

test_duration=$((SECONDS - test_start))
add_test_result "test_storage_scale_crds_established" "$test_status" "$test_duration" "$test_message"
