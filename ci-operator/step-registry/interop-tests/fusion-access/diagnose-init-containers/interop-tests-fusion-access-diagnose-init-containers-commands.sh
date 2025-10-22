#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_diagnose_init_containers_tests.xml"
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
  local test_classname="${5:-DiagnoseInitContainersTests}"
  
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
  <testsuite name="Diagnose Init Containers Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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

echo "🔬 Diagnosing IBM Storage Scale Init Containers..."

# Get daemon pods
DAEMON_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" -l scale.spectrum.ibm.com/daemon="${STORAGE_SCALE_CLUSTER_NAME}" -o name 2>/dev/null || echo "")

if [[ -z "$DAEMON_PODS" ]]; then
  echo "⚠️  No daemon pods found for diagnostics"
  echo "Namespace: ${STORAGE_SCALE_NAMESPACE}"
  echo "Cluster name: ${STORAGE_SCALE_CLUSTER_NAME}"
  exit 0
fi

POD_COUNT=$(echo "$DAEMON_PODS" | wc -w)
echo "Found ${POD_COUNT} daemon pod(s) to diagnose"
echo ""

# Test 1: Extract mmbuildgpl error messages
echo "🧪 Test 1: Extract mmbuildgpl error messages..."
test_start=$(date +%s)
test_status="failed"
test_message=""

ERROR_SUMMARY=""
UNIQUE_ERRORS=""

for pod in $DAEMON_PODS; do
  pod_name=$(basename "$pod")
  echo "  Checking pod: ${pod_name}"
  
  # Get full mmbuildgpl logs
  LOGS=$(oc logs "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -c mmbuildgpl 2>/dev/null || echo "")
  
  if [[ -n "$LOGS" ]]; then
    # Extract error lines
    ERRORS=$(echo "$LOGS" | grep -i "error" || echo "")
    
    if [[ -n "$ERRORS" ]]; then
      echo "    Found errors:"
      echo "$ERRORS" | sed 's/^/      /'
      
      # Add to summary
      if [[ -z "$UNIQUE_ERRORS" ]]; then
        UNIQUE_ERRORS="$ERRORS"
      fi
      
      ERROR_SUMMARY="${ERROR_SUMMARY}\n  Pod ${pod_name}:\n$(echo "$ERRORS" | sed 's/^/    /')"
    else
      echo "    No explicit error messages found"
    fi
  else
    echo "    No logs available (container may not have started)"
  fi
done

if [[ -z "$UNIQUE_ERRORS" ]]; then
  echo "  ℹ️  No error messages found in mmbuildgpl logs"
  test_status="passed"
else
  echo ""
  echo "  ❌ Error Summary:"
  echo -e "$ERROR_SUMMARY"
  test_message="mmbuildgpl init container errors found:${ERROR_SUMMARY}\n\nCommon errors:\n- 'Kernel module is not loaded yet' → Kernel module build/load failure\n- 'rsync error' → Missing lxtrace firmware files (usually non-critical)\n\nDIAGNOSTIC VALUE: These errors help identify the specific failure point in init container execution."
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_extract_mmbuildgpl_errors" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleInitContainerDiagnostics"

# Test 2: Check kernel version compatibility
echo ""
echo "🧪 Test 2: Check kernel version compatibility..."
test_start=$(date +%s)
test_status="failed"
test_message=""

# Get kernel versions from worker nodes
echo "  Collecting kernel versions from worker nodes..."
KERNEL_VERSIONS=""

for pod in $DAEMON_PODS; do
  pod_name=$(basename "$pod")
  NODE=$(oc get "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "")
  
  if [[ -n "$NODE" ]]; then
    KERNEL=$(oc get node "$NODE" -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null || echo "Unknown")
    OS_IMAGE=$(oc get node "$NODE" -o jsonpath='{.status.nodeInfo.osImage}' 2>/dev/null || echo "Unknown")
    
    echo "    Node ${NODE}:"
    echo "      Kernel: ${KERNEL}"
    echo "      OS: ${OS_IMAGE}"
    
    if [[ -z "$KERNEL_VERSIONS" ]]; then
      KERNEL_VERSIONS="${KERNEL}"
    fi
  fi
done

# Get Storage Scale version from pod image
STORAGE_SCALE_VERSION="Unknown"
if [[ -n "$DAEMON_PODS" ]]; then
  FIRST_POD=$(echo "$DAEMON_PODS" | head -1)
  STORAGE_SCALE_VERSION=$(oc get "$FIRST_POD" -n "${STORAGE_SCALE_NAMESPACE}" \
    -o jsonpath='{.spec.initContainers[?(@.name=="mmbuildgpl")].image}' 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+\.\d+' || echo "Unknown")
fi

echo ""
echo "  ℹ️  Compatibility Information:"
echo "    Storage Scale Version: ${STORAGE_SCALE_VERSION}"
echo "    Kernel Version: ${KERNEL_VERSIONS}"
echo ""
echo "  ⚠️  COMPATIBILITY CHECK:"
echo "    If mmbuildgpl is failing, this combination may not be supported."
echo "    Check IBM Storage Scale compatibility matrix for this kernel version."

test_message="COMPATIBILITY INFORMATION:\n- Storage Scale Version: ${STORAGE_SCALE_VERSION}\n- Kernel Version: ${KERNEL_VERSIONS}\n\nIf init containers are failing, verify this combination is supported in IBM Storage Scale compatibility documentation.\n\nKnown issue: Newer RHEL CoreOS kernels may not be supported by older Storage Scale versions.\nSolution: Upgrade Storage Scale or test on compatible OCP version."
test_status="passed"  # Informational test

test_duration=$(($(date +%s) - test_start))
add_test_result "test_kernel_version_compatibility" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleInitContainerDiagnostics"

# Test 3: Verify buildgpl ConfigMap exists
echo ""
echo "🧪 Test 3: Verify buildgpl ConfigMap exists..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if oc get configmap buildgpl -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "  ✅ ConfigMap 'buildgpl' exists"
  
  # Get ConfigMap size
  CM_DATA=$(oc get configmap buildgpl -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.data}' 2>/dev/null || echo "{}")
  CM_SIZE=$(echo "$CM_DATA" | wc -c)
  
  echo "    ConfigMap data size: ${CM_SIZE} bytes"
  
  if [[ "$CM_SIZE" -gt 10 ]]; then
    echo "  ✅ ConfigMap appears to be populated"
    test_status="passed"
  else
    echo "  ⚠️  ConfigMap may be empty or minimal"
    test_message="ConfigMap 'buildgpl' exists but appears to have minimal data (${CM_SIZE} bytes).\nThis may indicate configuration issues, but could also be normal if operator uses defaults."
    test_status="passed"  # Not necessarily a failure
  fi
else
  echo "  ❌ ConfigMap 'buildgpl' not found"
  test_message="ConfigMap 'buildgpl' not found in namespace ${STORAGE_SCALE_NAMESPACE}.\nThis ConfigMap should be created by the operator and contains build parameters for kernel module compilation.\nIf missing, operator may not have fully reconciled the Cluster CR."
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_buildgpl_configmap_exists" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleInitContainerDiagnostics"

# Test 4: Check init container image version
echo ""
echo "🧪 Test 4: Check init container image versions..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if [[ -z "$DAEMON_PODS" ]]; then
  echo "  ⚠️  No daemon pods to check"
  test_message="No daemon pods found"
  test_status="passed"
else
  FIRST_POD=$(echo "$DAEMON_PODS" | head -1)
  pod_name=$(basename "$FIRST_POD")
  
  # Get mmbuildgpl image
  MMBUILDGPL_IMAGE=$(oc get "$FIRST_POD" -n "${STORAGE_SCALE_NAMESPACE}" \
    -o jsonpath='{.spec.initContainers[?(@.name=="mmbuildgpl")].image}' 2>/dev/null || echo "Unknown")
  
  # Get config image
  CONFIG_IMAGE=$(oc get "$FIRST_POD" -n "${STORAGE_SCALE_NAMESPACE}" \
    -o jsonpath='{.spec.initContainers[?(@.name=="config")].image}' 2>/dev/null || echo "Unknown")
  
  # Get gpfs main container image
  GPFS_IMAGE=$(oc get "$FIRST_POD" -n "${STORAGE_SCALE_NAMESPACE}" \
    -o jsonpath='{.spec.containers[?(@.name=="gpfs")].image}' 2>/dev/null || echo "Unknown")
  
  echo "  Container Images (from pod ${pod_name}):"
  echo "    mmbuildgpl (init): ${MMBUILDGPL_IMAGE}"
  echo "    config (init): ${CONFIG_IMAGE}"
  echo "    gpfs (main): ${GPFS_IMAGE}"
  
  # Extract version/digest info
  VERSION_INFO="Container Images:\n- mmbuildgpl: ${MMBUILDGPL_IMAGE}\n- config: ${CONFIG_IMAGE}\n- gpfs: ${GPFS_IMAGE}\n\nUse this information to:\n- Verify correct Storage Scale version is deployed\n- Check if images are pulling correctly\n- Compare with known working versions"
  
  test_message="$VERSION_INFO"
  test_status="passed"  # Informational test
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_init_container_image_version" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleInitContainerDiagnostics"

# Test 5: Verify init container restart pattern
echo ""
echo "🧪 Test 5: Analyze init container restart patterns..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if [[ -z "$DAEMON_PODS" ]]; then
  echo "  ⚠️  No daemon pods to check"
  test_message="No daemon pods found"
  test_status="passed"
else
  TOTAL_RESTARTS=0
  RESTART_DETAILS=""
  HIGH_RESTART_PODS=0
  
  for pod in $DAEMON_PODS; do
    pod_name=$(basename "$pod")
    
    # Get restart count for mmbuildgpl
    RESTART_COUNT=$(oc get "$pod" -n "${STORAGE_SCALE_NAMESPACE}" \
      -o jsonpath='{.status.initContainerStatuses[?(@.name=="mmbuildgpl")].restartCount}' 2>/dev/null || echo "0")
    
    TOTAL_RESTARTS=$((TOTAL_RESTARTS + RESTART_COUNT))
    
    echo "    Pod ${pod_name}: ${RESTART_COUNT} restarts"
    RESTART_DETAILS="${RESTART_DETAILS}\n    ${pod_name}: ${RESTART_COUNT} restarts"
    
    if [[ "$RESTART_COUNT" -gt 5 ]]; then
      HIGH_RESTART_PODS=$((HIGH_RESTART_PODS + 1))
    fi
  done
  
  echo ""
  echo "  Total restarts across all pods: ${TOTAL_RESTARTS}"
  echo "  Pods with >5 restarts: ${HIGH_RESTART_PODS}"
  
  if [[ "$TOTAL_RESTARTS" -eq 0 ]]; then
    echo "  ✅ No init container restarts (healthy)"
    test_status="passed"
  elif [[ "$HIGH_RESTART_PODS" -eq 0 ]]; then
    echo "  ℹ️  Low restart count (transient issues)"
    test_message="Init containers have restarted ${TOTAL_RESTARTS} times total.\nRestart details:${RESTART_DETAILS}\n\nLow restart counts (<6) may indicate transient issues or ongoing initialization.\nMonitor for continued restarts."
    test_status="passed"
  else
    echo "  ❌ SYSTEMATIC FAILURE: ${HIGH_RESTART_PODS} pod(s) with high restart counts"
    test_message="❌ SYSTEMATIC FAILURE DETECTED:\n- Total restarts: ${TOTAL_RESTARTS}\n- Pods with >5 restarts: ${HIGH_RESTART_PODS}\n\nRestart details:${RESTART_DETAILS}\n\nDIAGNOSIS:\nHigh restart counts (>5) indicate systematic failure, not transient issues.\nThe init container is consistently failing for the same reason.\n\nRECOMMENDATION:\n- Check Test 1 for specific error messages\n- Check Test 2 for version compatibility\n- This is likely a product compatibility issue requiring:\n  a) Storage Scale version upgrade\n  b) OpenShift version change\n  c) IBM support engagement"
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_init_container_restart_pattern" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleInitContainerDiagnostics"

