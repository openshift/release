#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_wait_for_cluster_tests.xml"
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
  local test_classname="${5:-ClusterCreationTests}"
  
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
  <testsuite name="Wait for Cluster Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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
  
  # Exit with failure if any tests failed
  if [[ ${TESTS_FAILED} -gt 0 ]]; then
    echo ""
    echo "❌ Test suite failed: ${TESTS_FAILED} test(s) failed"
    exit 1
  fi
}

# Trap to ensure JUnit XML is generated even on failure
trap generate_junit_xml EXIT

echo "⏳ Waiting for FusionAccess operator to create IBM Storage Scale Cluster..."

# Test 1: Wait for Cluster to be created by operator
echo ""
echo "🧪 Test 1: Wait for Cluster creation by FusionAccess operator..."
TEST1_START=$(date +%s)
TEST1_STATUS="failed"
TEST1_MESSAGE=""

MAX_WAIT=600  # 10 minutes
ELAPSED=0
INTERVAL=10

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
    echo "  ✅ Cluster ${STORAGE_SCALE_CLUSTER_NAME} created by operator"
    TEST1_STATUS="passed"
    break
  fi
  
  echo "  ⏳ Waiting for operator to create Cluster... (${ELAPSED}s/${MAX_WAIT}s)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [[ "$TEST1_STATUS" != "passed" ]]; then
  TEST1_MESSAGE="FusionAccess operator did not create Cluster within ${MAX_WAIT}s. Check FusionAccess CR status and operator logs."
  echo "  ❌ Timeout waiting for Cluster creation"
  echo "  FusionAccess CR status:"
  oc get fusionaccess -n ibm-fusion-access -o yaml || echo "Failed to get FusionAccess CR"
fi

TEST1_DURATION=$(($(date +%s) - TEST1_START))
add_test_result "test_cluster_created_by_operator" "$TEST1_STATUS" "$TEST1_DURATION" "$TEST1_MESSAGE" "ClusterCreationTests"

# Test 2: Verify Cluster has device configuration
echo ""
echo "🧪 Test 2: Verify Cluster has device configuration..."
TEST2_START=$(date +%s)
TEST2_STATUS="failed"
TEST2_MESSAGE=""

if [[ "$TEST1_STATUS" == "passed" ]]; then
  # Check if Cluster has nsdDevicesConfig
  DEVICE_CONFIG=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" \
    -o jsonpath='{.spec.daemon.nsdDevicesConfig}' 2>/dev/null || echo "")
  
  if [[ -n "$DEVICE_CONFIG" ]]; then
    echo "  ✅ Cluster has device configuration"
    echo "  Device config: ${DEVICE_CONFIG}"
    TEST2_STATUS="passed"
  else
    TEST2_MESSAGE="Cluster exists but has no nsdDevicesConfig. Operator may not have completed device discovery."
    echo "  ⚠️  No device configuration found"
  fi
else
  TEST2_MESSAGE="Skipped - Cluster was not created"
  echo "  ⚠️  Skipped - Cluster not created"
fi

TEST2_DURATION=$(($(date +%s) - TEST2_START))
add_test_result "test_cluster_has_device_config" "$TEST2_STATUS" "$TEST2_DURATION" "$TEST2_MESSAGE" "ClusterCreationTests"

# Test 3: Verify devices match EBS volumes
echo ""
echo "🧪 Test 3: Verify auto-discovered devices..."
TEST3_START=$(date +%s)
TEST3_STATUS="failed"
TEST3_MESSAGE=""

if [[ "$TEST2_STATUS" == "passed" ]]; then
  # Get configured device paths
  DEVICE_PATHS=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" \
    -o jsonpath='{.spec.daemon.nsdDevicesConfig.localDevicePaths[*].devicePath}' 2>/dev/null || echo "")
  
  if [[ -n "$DEVICE_PATHS" ]]; then
    DEVICE_COUNT=$(echo "$DEVICE_PATHS" | wc -w)
    echo "  ✅ Found ${DEVICE_COUNT} configured devices: ${DEVICE_PATHS}"
    TEST3_STATUS="passed"
  else
    TEST3_MESSAGE="No device paths found in Cluster configuration"
    echo "  ⚠️  No device paths configured"
  fi
else
  TEST3_MESSAGE="Skipped - Cluster has no device configuration"
  echo "  ⚠️  Skipped"
fi

TEST3_DURATION=$(($(date +%s) - TEST3_START))
add_test_result "test_devices_auto_discovered" "$TEST3_STATUS" "$TEST3_DURATION" "$TEST3_MESSAGE" "ClusterCreationTests"

# Display final Cluster status
echo ""
echo "📊 Cluster Status:"
oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" || echo "Cluster not found"
