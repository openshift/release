#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_verify_filesystem_tests.xml"
TEST_START_TIME=$(date +%s)
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
  local test_classname="${5:-VerifyFilesystemTests}"
  
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

# Function to generate JUnit XML report
generate_junit_xml() {
  local total_duration=$(($(date +%s) - TEST_START_TIME))
  
  cat > "${JUNIT_RESULTS_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Verify Filesystem Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/$(basename ${JUNIT_RESULTS_FILE})"
    echo "  ✅ Results copied to SHARED_DIR"
  fi
}

# Trap to ensure JUnit XML is generated even on failure
trap generate_junit_xml EXIT

echo "🔍 Verifying IBM Storage Scale Filesystem..."

# Test 1: Verify filesystem exists
echo ""
echo "🧪 Test 1: Verify filesystem exists..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} >/dev/null 2>&1; then
  echo "  ✅ Filesystem shared-filesystem exists"
  oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE}
  test_status="passed"
else
  echo "  ❌ Filesystem shared-filesystem not found"
  test_message="Filesystem shared-filesystem not found in namespace ${STORAGE_SCALE_NAMESPACE}"
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_filesystem_exists" "$test_status" "$test_duration" "$test_message"

# Test 2: Check filesystem conditions
echo ""
echo "🧪 Test 2: Check filesystem conditions..."
test_start=$(date +%s)
test_status="failed"
test_message=""

echo "  Filesystem conditions:"
oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} \
  -o jsonpath='{range .status.conditions[*]}    {.type}: {.status} - {.message}{"\n"}{end}'

# Check if filesystem has Success condition with status True
SUCCESS_STATUS=$(oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} \
  -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")

if [[ "${SUCCESS_STATUS}" == "True" ]]; then
  echo "  ✅ Filesystem condition Success=True"
  test_status="passed"
else
  echo "  ⚠️  Filesystem condition Success=${SUCCESS_STATUS}"
  test_message="Filesystem Success condition is ${SUCCESS_STATUS}, expected True"
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_filesystem_success_condition" "$test_status" "$test_duration" "$test_message"

# Test 3: Verify StorageClass was created
echo ""
echo "🧪 Test 3: Verify StorageClass creation..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if oc get storageclass | grep -q spectrum; then
  echo "  ✅ StorageClass created:"
  oc get storageclass | grep spectrum
  test_status="passed"
else
  echo "  ❌ StorageClass not found"
  test_message="IBM Spectrum Scale StorageClass not found"
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_storageclass_created" "$test_status" "$test_duration" "$test_message"
