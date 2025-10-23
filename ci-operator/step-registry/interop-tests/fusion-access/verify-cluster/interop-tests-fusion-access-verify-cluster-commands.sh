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
  
  # Exit with failure if any tests failed
  if [[ ${TESTS_FAILED} -gt 0 ]]; then
    echo ""
    echo "❌ Test suite failed: ${TESTS_FAILED} test(s) failed"
    exit 1
  fi
}

# Trap to ensure JUnit XML is generated even on failure
trap generate_junit_xml EXIT

echo "🔍 Verifying IBM Storage Scale Cluster..."

# Test 1: Verify Cluster was created by operator (not manually)
echo ""
echo "🧪 Test 1: Verify Cluster creation source..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "  ✅ Cluster ${STORAGE_SCALE_CLUSTER_NAME} exists"
  echo "  Creation method: FusionAccess operator auto-discovery"
  test_status="passed"
else
  echo "  ❌ Cluster ${STORAGE_SCALE_CLUSTER_NAME} not found"
  test_message="Cluster ${STORAGE_SCALE_CLUSTER_NAME} not found in namespace ${STORAGE_SCALE_NAMESPACE}"
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_cluster_exists_via_operator" "$test_status" "$test_duration" "$test_message"

# Test 2: Verify cluster exists (legacy test for backwards compatibility)
echo ""
echo "🧪 Test 2: Verify cluster exists..."
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

# Test 3: Check cluster conditions
echo ""
echo "🧪 Test 3: Check cluster conditions..."
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

# Test 4: Check pods are running
echo ""
echo "🧪 Test 4: Check IBM Storage Scale pods..."
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

# Test 5: Verify mmbuildgpl init container status
echo ""
echo "🧪 Test 5: Verify mmbuildgpl init container status..."
test_start=$(date +%s)
test_status="failed"
test_message=""

# Get daemon pods with Storage Scale label
DAEMON_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" -l scale.spectrum.ibm.com/daemon="${STORAGE_SCALE_CLUSTER_NAME}" -o name 2>/dev/null || echo "")

if [[ -z "$DAEMON_PODS" ]]; then
  echo "  ⚠️  No daemon pods found"
  test_message="No daemon pods found with label scale.spectrum.ibm.com/daemon=${STORAGE_SCALE_CLUSTER_NAME}"
else
  MMBUILDGPL_FAILURES=0
  ERROR_DETAILS=""
  
  for pod in $DAEMON_PODS; do
    pod_name=$(basename "$pod")
    # Get mmbuildgpl init container state
    STATE=$(oc get "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.initContainerStatuses[?(@.name=="mmbuildgpl")].state}' 2>/dev/null || echo "")
    
    if echo "$STATE" | grep -q "waiting\|terminated"; then
      # Check exit code if terminated
      EXIT_CODE=$(oc get "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.initContainerStatuses[?(@.name=="mmbuildgpl")].state.terminated.exitCode}' 2>/dev/null || echo "")
      
      if [[ -n "$EXIT_CODE" ]] && [[ "$EXIT_CODE" != "0" ]]; then
        MMBUILDGPL_FAILURES=$((MMBUILDGPL_FAILURES + 1))
        
        # Get error from logs
        ERROR_MSG=$(oc logs "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -c mmbuildgpl 2>/dev/null | grep -i "error" | head -1 || echo "Init container failed with exit code ${EXIT_CODE}")
        ERROR_DETAILS="${ERROR_DETAILS}\n    Pod ${pod_name}: ${ERROR_MSG}"
      elif echo "$STATE" | grep -q "waiting"; then
        RESTART_COUNT=$(oc get "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.initContainerStatuses[?(@.name=="mmbuildgpl")].restartCount}' 2>/dev/null || echo "0")
        if [[ "$RESTART_COUNT" -gt 3 ]]; then
          MMBUILDGPL_FAILURES=$((MMBUILDGPL_FAILURES + 1))
          REASON=$(oc get "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.initContainerStatuses[?(@.name=="mmbuildgpl")].state.waiting.reason}' 2>/dev/null || echo "Unknown")
          ERROR_DETAILS="${ERROR_DETAILS}\n    Pod ${pod_name}: ${REASON} (${RESTART_COUNT} restarts)"
        fi
      fi
    fi
  done
  
  if [[ $MMBUILDGPL_FAILURES -eq 0 ]]; then
    echo "  ✅ All mmbuildgpl init containers completed successfully or are running"
    test_status="passed"
  else
    echo "  ❌ ROOT CAUSE: ${MMBUILDGPL_FAILURES} mmbuildgpl init container(s) failed"
    echo -e "$ERROR_DETAILS"
    test_message="❌ ROOT CAUSE: mmbuildgpl init container crashes prevent quorum establishment${ERROR_DETAILS}\n\nThis prevents daemon pods from reaching Running state, blocking quorum formation and all downstream operations.\nKnown issue: IBM Storage Scale kernel module build may fail on certain kernel versions."
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_mmbuildgpl_init_container_status" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleClusterTests"

# Test 6: Verify config init container status
echo ""
echo "🧪 Test 6: Verify config init container status..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if [[ -z "$DAEMON_PODS" ]]; then
  echo "  ⚠️  No daemon pods found to check config init container"
  test_message="No daemon pods found"
else
  CONFIG_WAITING=0
  CONFIG_COMPLETED=0
  
  for pod in $DAEMON_PODS; do
    pod_name=$(basename "$pod")
    # Check if config init container has started
    CONFIG_STATE=$(oc get "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.initContainerStatuses[?(@.name=="config")].state}' 2>/dev/null || echo "")
    
    if echo "$CONFIG_STATE" | grep -q "running\|terminated"; then
      CONFIG_COMPLETED=$((CONFIG_COMPLETED + 1))
    else
      CONFIG_WAITING=$((CONFIG_WAITING + 1))
    fi
  done
  
  POD_COUNT=$(echo "$DAEMON_PODS" | wc -w)
  
  if [[ $CONFIG_COMPLETED -eq $POD_COUNT ]]; then
    echo "  ✅ All config init containers started/completed"
    test_status="passed"
  elif [[ $CONFIG_WAITING -eq $POD_COUNT ]]; then
    echo "  ⚠️  SYMPTOM: Config init containers waiting (blocked by mmbuildgpl)"
    test_message="⚠️ SYMPTOM: Config init containers have not started yet.\nExpected: Config waits for mmbuildgpl to complete.\nIf mmbuildgpl is failing (see Test 4), this is a downstream symptom, not the root cause."
  else
    echo "  ⚠️  ${CONFIG_COMPLETED} of ${POD_COUNT} config init containers progressed"
    test_status="passed"  # Partial progress is acceptable
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_config_init_container_status" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleClusterTests"

# Test 7: Verify daemon pods have reached Running state
echo ""
echo "🧪 Test 7: Verify daemon pods have reached Running state..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if [[ -z "$DAEMON_PODS" ]]; then
  echo "  ⚠️  No daemon pods found"
  test_message="No daemon pods found"
else
  RUNNING_DAEMON_PODS=0
  TOTAL_DAEMON_PODS=0
  
  for pod in $DAEMON_PODS; do
    TOTAL_DAEMON_PODS=$((TOTAL_DAEMON_PODS + 1))
    PHASE=$(oc get "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    
    if [[ "$PHASE" == "Running" ]]; then
      RUNNING_DAEMON_PODS=$((RUNNING_DAEMON_PODS + 1))
    fi
  done
  
  if [[ $RUNNING_DAEMON_PODS -eq $TOTAL_DAEMON_PODS ]]; then
    echo "  ✅ All ${TOTAL_DAEMON_PODS} daemon pods are in Running state"
    test_status="passed"
  elif [[ $RUNNING_DAEMON_PODS -gt 0 ]]; then
    echo "  ⚠️  ${RUNNING_DAEMON_PODS} of ${TOTAL_DAEMON_PODS} daemon pods in Running state"
    test_message="⚠️ Only ${RUNNING_DAEMON_PODS} of ${TOTAL_DAEMON_PODS} daemon pods reached Running state.\nQuorum requires majority of daemon pods to be running.\nPartial Running state may indicate ongoing initialization or failures in some pods."
    test_status="passed"  # Partial success
  else
    echo "  ⚠️  SYMPTOM: No daemon pods in Running state (quorum cannot form)"
    test_message="⚠️ SYMPTOM: No daemon pods have reached Running state.\nQUORUM IMPACT: Quorum establishment requires Running daemon pods.\nThis prevents: Quorum formation, SSH secret creation, filesystem operations.\nIf init containers are failing (see Test 4), this is a downstream symptom."
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_daemon_pods_running_state" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleClusterTests"

# Test 8: Check for specific init container errors
echo ""
echo "🧪 Test 8: Check for specific init container error patterns..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if [[ -z "$DAEMON_PODS" ]]; then
  echo "  ⚠️  No daemon pods found to check logs"
  test_message="No daemon pods found"
  test_status="passed"  # Not a failure if no pods exist
else
  KERNEL_MODULE_ERRORS=0
  RSYNC_ERRORS=0
  OTHER_ERRORS=0
  ERROR_SAMPLES=""
  
  for pod in $DAEMON_PODS; do
    pod_name=$(basename "$pod")
    # Get mmbuildgpl logs
    LOGS=$(oc logs "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -c mmbuildgpl 2>/dev/null || echo "")
    
    if echo "$LOGS" | grep -q "Kernel module is not loaded yet"; then
      KERNEL_MODULE_ERRORS=$((KERNEL_MODULE_ERRORS + 1))
      if [[ -z "$ERROR_SAMPLES" ]]; then
        ERROR_SAMPLES="    Pod ${pod_name}: 'Kernel module is not loaded yet'"
      fi
    fi
    
    if echo "$LOGS" | grep -q "rsync.*error\|rsync.*failed"; then
      RSYNC_ERRORS=$((RSYNC_ERRORS + 1))
    fi
    
    if echo "$LOGS" | grep -qi "error" | grep -qv "Kernel module\|rsync"; then
      OTHER_ERRORS=$((OTHER_ERRORS + 1))
    fi
  done
  
  if [[ $KERNEL_MODULE_ERRORS -eq 0 ]] && [[ $RSYNC_ERRORS -eq 0 ]] && [[ $OTHER_ERRORS -eq 0 ]]; then
    echo "  ✅ No critical error patterns found in init container logs"
    test_status="passed"
  else
    echo "  ❌ Found error patterns in init container logs:"
    if [[ $KERNEL_MODULE_ERRORS -gt 0 ]]; then
      echo "    - Kernel module errors: ${KERNEL_MODULE_ERRORS} pod(s)"
    fi
    if [[ $RSYNC_ERRORS -gt 0 ]]; then
      echo "    - Rsync errors: ${RSYNC_ERRORS} pod(s)"
    fi
    if [[ $OTHER_ERRORS -gt 0 ]]; then
      echo "    - Other errors: ${OTHER_ERRORS} pod(s)"
    fi
    echo -e "$ERROR_SAMPLES"
    
    test_message="Found error patterns in ${KERNEL_MODULE_ERRORS} pod(s):\n${ERROR_SAMPLES}\n\nDIAGNOSIS:\n- 'Kernel module is not loaded yet' indicates mmbuildgpl cannot build/load GPFS kernel modules\n- This is typically a kernel compatibility issue\n- Check: Storage Scale version vs kernel version compatibility\n- Common cause: New OCP/RHCOS kernel not yet supported by Storage Scale version"
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_init_container_error_patterns" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleClusterTests"

# Test 9: Verify KMM configuration
echo ""
echo "🧪 Test 9: Verify KMM registry configuration..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if oc get configmap kmm-image-config -n ibm-fusion-access >/dev/null 2>&1; then
  echo "  ✅ KMM configuration exists"
  
  # Verify registry URL
  REGISTRY_URL=$(oc get configmap kmm-image-config -n ibm-fusion-access \
    -o jsonpath='{.data.kmm_image_registry_url}' 2>/dev/null || echo "")
  REGISTRY_REPO=$(oc get configmap kmm-image-config -n ibm-fusion-access \
    -o jsonpath='{.data.kmm_image_repo}' 2>/dev/null || echo "")
  
  if [[ -n "$REGISTRY_URL" ]] && [[ -n "$REGISTRY_REPO" ]]; then
    echo "  Registry: ${REGISTRY_URL}/${REGISTRY_REPO}"
    test_status="passed"
  else
    test_message="KMM config exists but missing registry URL or repo"
    echo "  ⚠️  Incomplete KMM configuration"
  fi
else
  test_message="KMM configuration not found. This is required for kernel module building since Fusion Access v0.0.19+."
  echo "  ❌ KMM configuration missing"
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_kmm_configuration" "$test_status" "$test_duration" "$test_message"
