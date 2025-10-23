#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"
STORAGE_SCALE_CLIENT_CPU="${STORAGE_SCALE_CLIENT_CPU:-2}"
STORAGE_SCALE_CLIENT_MEMORY="${STORAGE_SCALE_CLIENT_MEMORY:-4Gi}"
STORAGE_SCALE_STORAGE_CPU="${STORAGE_SCALE_STORAGE_CPU:-2}"
STORAGE_SCALE_STORAGE_MEMORY="${STORAGE_SCALE_STORAGE_MEMORY:-8Gi}"

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_create_cluster_tests.xml"
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
  <testsuite name="Create Cluster Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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

echo "🏗️  Creating IBM Storage Scale Cluster..."

# Test 1: Check if cluster already exists (idempotent)
echo ""
echo "🧪 Test 1: Check cluster pre-existence..."
TEST1_START=$(date +%s)
TEST1_STATUS="passed"
TEST1_MESSAGE=""

if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "  ✅ Cluster already exists (idempotent)"
  CLUSTER_EXISTS=true
else
  echo "  ℹ️  Cluster does not exist, will create"
  CLUSTER_EXISTS=false
fi

TEST1_DURATION=$(($(date +%s) - TEST1_START))
add_test_result "test_cluster_idempotency_check" "$TEST1_STATUS" "$TEST1_DURATION" "$TEST1_MESSAGE"

# Test 2: Create Cluster resource (without hardcoded device paths)
if [[ "$CLUSTER_EXISTS" == "false" ]]; then
  echo ""
  echo "🧪 Test 2: Create Cluster resource..."
  TEST2_START=$(date +%s)
  TEST2_STATUS="failed"
  TEST2_MESSAGE=""
  
  # Determine quorum configuration based on worker count
  WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
  
  if [[ $WORKER_COUNT -ge 3 ]]; then
    QUORUM_CONFIG="quorum:
    autoAssign: true"
  else
    echo "  ⚠️  Only $WORKER_COUNT worker nodes (3 recommended for quorum)"
    QUORUM_CONFIG=""
  fi
  
  # Create cluster WITHOUT hardcoded device paths
  # Let the operator discover devices via LocalVolumeDiscovery or use Filesystem's disk refs
  if cat <<EOF | oc apply -f -
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Cluster
metadata:
  name: ${STORAGE_SCALE_CLUSTER_NAME}
  namespace: ${STORAGE_SCALE_NAMESPACE}
spec:
  license:
    accept: true
    license: data-management
  pmcollector:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
  daemon:
    nodeSelector:
      scale.spectrum.ibm.com/role: storage
    nsdDevicesConfig:
      localDevicePaths:
      - devicePath: /dev/disk/by-id/*
        deviceType: generic
    clusterProfile:
      controlSetxattrImmutableSELinux: "yes"
      enforceFilesetQuotaOnRoot: "yes"
      ignorePrefetchLUNCount: "yes"
      initPrefetchBuffers: "128"
      maxblocksize: 16M
      prefetchPct: "25"
      prefetchTimeout: "30"
    roles:
    - name: client
      resources:
        cpu: "${STORAGE_SCALE_CLIENT_CPU}"
        memory: ${STORAGE_SCALE_CLIENT_MEMORY}
    - name: storage
      resources:
        cpu: "${STORAGE_SCALE_STORAGE_CPU}"
        memory: ${STORAGE_SCALE_STORAGE_MEMORY}
  ${QUORUM_CONFIG}
EOF
  then
    echo "  ✅ Cluster resource created successfully"
    TEST2_STATUS="passed"
  else
    echo "  ❌ Failed to create Cluster resource"
    TEST2_MESSAGE="Failed to create Cluster resource via oc apply"
  fi
  
  TEST2_DURATION=$(($(date +%s) - TEST2_START))
  add_test_result "test_cluster_creation" "$TEST2_STATUS" "$TEST2_DURATION" "$TEST2_MESSAGE"
else
  echo ""
  echo "  ℹ️  Skipping Cluster creation (already exists)"
fi

# Test 3: Verify Cluster resource exists
echo ""
echo "🧪 Test 3: Verify Cluster resource..."
TEST3_START=$(date +%s)
TEST3_STATUS="failed"
TEST3_MESSAGE=""

if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "  ✅ Cluster resource verified"
  TEST3_STATUS="passed"
else
  echo "  ❌ Cluster resource not found after creation"
  TEST3_MESSAGE="Cluster ${STORAGE_SCALE_CLUSTER_NAME} not found in namespace ${STORAGE_SCALE_NAMESPACE}"
fi

TEST3_DURATION=$(($(date +%s) - TEST3_START))
add_test_result "test_cluster_exists" "$TEST3_STATUS" "$TEST3_DURATION" "$TEST3_MESSAGE"

# Test 4: Verify Cluster has correct device pattern
echo ""
echo "🧪 Test 4: Verify Cluster device configuration..."
TEST4_START=$(date +%s)
TEST4_STATUS="failed"
TEST4_MESSAGE=""

DEVICE_PATH=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" \
  -o jsonpath='{.spec.daemon.nsdDevicesConfig.localDevicePaths[0].devicePath}' 2>/dev/null || echo "")

if [[ "$DEVICE_PATH" == "/dev/disk/by-id/*" ]]; then
  echo "  ✅ Cluster configured with /dev/disk/by-id/* device pattern"
  TEST4_STATUS="passed"
elif [[ -n "$DEVICE_PATH" ]]; then
  echo "  ⚠️  Cluster has device path: ${DEVICE_PATH}"
  TEST4_MESSAGE="Cluster has unexpected device path: ${DEVICE_PATH} (expected: /dev/disk/by-id/*)"
else
  echo "  ⚠️  Cluster has no nsdDevicesConfig"
  TEST4_MESSAGE="Cluster missing nsdDevicesConfig.localDevicePaths"
fi

TEST4_DURATION=$(($(date +%s) - TEST4_START))
add_test_result "test_cluster_device_pattern" "$TEST4_STATUS" "$TEST4_DURATION" "$TEST4_MESSAGE"

# Display Cluster status
echo ""
echo "📊 Cluster Status:"
oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" || echo "Cluster not found"

echo ""
echo "Note: Cluster initialization may take several minutes"
echo "Daemon pods will use /dev/disk/by-id/* pattern to discover EBS volumes"
echo "KMM will build kernel modules using Driver Toolkit"
