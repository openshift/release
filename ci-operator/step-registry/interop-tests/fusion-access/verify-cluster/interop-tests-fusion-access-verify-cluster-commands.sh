#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_verify_cluster_tests.xml"
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
  local test_classname="${5:-VerifyClusterTests}"
  
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
  <testsuite name="Verify Cluster Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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

echo "🔍 Verifying IBM Storage Scale Cluster..."

# Test 1: Verify cluster exists
echo ""
echo "🧪 Test 1: Verify cluster exists..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "  ✅ Cluster ${STORAGE_SCALE_CLUSTER_NAME} exists"
  test_status="passed"
else
  echo "  ❌ Cluster ${STORAGE_SCALE_CLUSTER_NAME} not found"
  test_message="Cluster ${STORAGE_SCALE_CLUSTER_NAME} not found in namespace ${STORAGE_SCALE_NAMESPACE}"
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_cluster_exists" "$test_status" "$test_duration" "$test_message"

# Test 2: Check cluster conditions
echo ""
echo "🧪 Test 2: Check cluster conditions..."
test_start=$(date +%s)
test_status="failed"
test_message=""

echo "  Cluster conditions:"
oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" \
  -o jsonpath='{range .status.conditions[*]}    {.type}: {.status} - {.message}{"\n"}{end}'

# Check if cluster has Success condition with status True
SUCCESS_STATUS=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")

if [[ "${SUCCESS_STATUS}" == "True" ]]; then
  echo "  ✅ Cluster condition Success=True"
  test_status="passed"
else
  echo "  ⚠️  Cluster condition Success=${SUCCESS_STATUS}"
  test_message="Cluster Success condition is ${SUCCESS_STATUS}, expected True"
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_cluster_success_condition" "$test_status" "$test_duration" "$test_message"

# Test 3: Check pods are running
echo ""
echo "🧪 Test 3: Check IBM Storage Scale pods..."
test_start=$(date +%s)
test_status="failed"
test_message=""

echo "  IBM Storage Scale pods:"
oc get pods -n "${STORAGE_SCALE_NAMESPACE}"

# Count running pods
RUNNING_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
TOTAL_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)

if [[ $RUNNING_PODS -gt 0 ]] && [[ $RUNNING_PODS -eq $TOTAL_PODS ]]; then
  echo "  ✅ All ${TOTAL_PODS} pods are running"
  test_status="passed"
elif [[ $RUNNING_PODS -gt 0 ]]; then
  echo "  ⚠️  ${RUNNING_PODS} of ${TOTAL_PODS} pods are running"
  test_message="${RUNNING_PODS} of ${TOTAL_PODS} pods are running"
else
  echo "  ❌ No running pods found"
  test_message="No running pods found in namespace ${STORAGE_SCALE_NAMESPACE}"
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_cluster_pods_running" "$test_status" "$test_duration" "$test_message"
