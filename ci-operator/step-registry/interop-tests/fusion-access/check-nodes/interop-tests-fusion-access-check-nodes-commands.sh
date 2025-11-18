#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_check_nodes_tests.xml"
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
  local test_classname="${5:-CheckNodesTests}"
  
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
  <testsuite name="Check Nodes Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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

echo "🔍 Checking worker nodes..."

# Test 1: Verify minimum worker node count for quorum
test_start=$(date +%s)
test_status="failed"
test_message=""

WORKER_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

if [[ $WORKER_NODE_COUNT -lt 3 ]]; then
  echo "⚠️  WARNING: Only $WORKER_NODE_COUNT worker nodes (minimum 3 required for quorum)"
  test_message="Insufficient worker nodes: found $WORKER_NODE_COUNT, minimum 3 required for quorum"
else
  echo "✅ Found $WORKER_NODE_COUNT worker nodes (quorum requirements met)"
  test_status="passed"
fi

echo ""
echo "Worker nodes:"
oc get nodes -l node-role.kubernetes.io/worker

test_duration=$(($(date +%s) - test_start))
add_test_result "test_worker_node_count_for_quorum" "$test_status" "$test_duration" "$test_message"
