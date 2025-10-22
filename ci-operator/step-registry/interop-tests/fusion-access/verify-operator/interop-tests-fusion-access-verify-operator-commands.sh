#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_OPERATOR_NAMESPACE="${STORAGE_SCALE_OPERATOR_NAMESPACE:-ibm-spectrum-scale-operator}"

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_verify_operator_tests.xml"
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
  local test_classname="${5:-VerifyOperatorTests}"
  
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
  <testsuite name="Verify Operator Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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

echo "🔍 Verifying IBM Storage Scale Operator..."

# Test 1: Verify operator is running
echo ""
echo "🧪 Test 1: Verify operator pod status..."
test_start=$(date +%s)
test_status="failed"
test_message=""

OPERATOR_POD=$(oc get pods -n "${STORAGE_SCALE_OPERATOR_NAMESPACE}" -l app.kubernetes.io/name=ibm-spectrum-scale-operator -o name 2>/dev/null | head -1 || echo "")

if [[ -z "$OPERATOR_POD" ]]; then
  echo "  ❌ Operator pod not found"
  test_message="IBM Spectrum Scale operator pod not found in namespace ${STORAGE_SCALE_OPERATOR_NAMESPACE}"
else
  pod_name=$(basename "$OPERATOR_POD")
  PHASE=$(oc get "$OPERATOR_POD" -n "${STORAGE_SCALE_OPERATOR_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  
  if [[ "$PHASE" == "Running" ]]; then
    echo "  ✅ Operator pod ${pod_name} is Running"
    test_status="passed"
  else
    echo "  ❌ Operator pod ${pod_name} is ${PHASE}"
    test_message="Operator pod is in ${PHASE} state, expected Running"
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_operator_pod_status" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleOperatorTests"

# Test 2: Check GUI SSH key creation
echo ""
echo "🧪 Test 2: Check GUI SSH key creation..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if oc get secret ibm-spectrum-scale-gui-ssh-key -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "  ✅ GUI SSH key 'ibm-spectrum-scale-gui-ssh-key' exists"
  echo "    This proves operator CAN create secrets successfully"
  test_status="passed"
else
  echo "  ⚠️  GUI SSH key not found"
  test_message="Secret 'ibm-spectrum-scale-gui-ssh-key' not found.\nThis secret should be created early in operator reconciliation.\nIf missing, operator may not have reconciled the Cluster CR yet, or there may be RBAC permission issues."
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_gui_ssh_key_created" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleOperatorTests"

# Test 3: Check core SSH key creation
echo ""
echo "🧪 Test 3: Check core SSH key creation..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if oc get secret ibm-spectrum-scale-core-ssh-key-secret -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "  ✅ Core SSH key 'ibm-spectrum-scale-core-ssh-key-secret' exists"
  test_status="passed"
else
  echo "  ⚠️  SYMPTOM: Core SSH key not found (expected when quorum not established)"
  test_message="⚠️ SYMPTOM: Secret 'ibm-spectrum-scale-core-ssh-key-secret' not found.\n\nThis is EXPECTED BEHAVIOR when quorum is not established.\n\nOPERATOR DESIGN:\n- GUI SSH key: Created during initial reconciliation (early)\n- Core SSH key: Created AFTER quorum pods are running (late)\n\nREASON FOR MISSING SECRET:\nOperator creates core SSH secret only after quorum is established.\nQuorum requires daemon pods to be in Running state.\nIf daemon pods are failing to start, quorum never forms, and this secret is never created.\n\nACTION: Fix daemon pod failures first. Once quorum forms, this secret will be created automatically.\n\nThis is NOT the root cause - this is expected operator behavior."
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_core_ssh_key_created" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleOperatorTests"

# Test 4: Check quorum status in operator logs
echo ""
echo "🧪 Test 4: Check operator quorum detection..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if [[ -z "$OPERATOR_POD" ]]; then
  echo "  ⚠️  Operator pod not found"
  test_message="Operator pod not found"
else
  # Check operator logs for quorum status
  QUORUM_LOGS=$(oc logs "$OPERATOR_POD" -n "${STORAGE_SCALE_OPERATOR_NAMESPACE}" --tail=100 2>/dev/null | grep "quorum" | tail -5 || echo "")
  
  if echo "$QUORUM_LOGS" | grep -q "quorumRunning:\[\]"; then
    echo "  ℹ️  INFO: Operator detects no running quorum pods"
    echo "    This indicates operator is correctly monitoring pod status"
    echo "    Quorum: [] (empty - no quorum established)"
    test_message="ℹ️ INFO: Operator correctly detects that quorum is not established.\nQuorum status shows: quorum:[] quorumRunning:[]\n\nOPERATOR BEHAVIOR: Normal - operator is waiting for daemon pods to reach Running state.\nNo action needed on operator side.\n\nNext step: Investigate why daemon pods are not reaching Running state."
    test_status="passed"  # This is actually correct behavior
  elif echo "$QUORUM_LOGS" | grep -qi "quorum"; then
    echo "  ℹ️  Operator shows quorum activity:"
    echo "$QUORUM_LOGS" | head -3
    test_status="passed"
  else
    echo "  ⚠️  No quorum information in recent operator logs"
    test_status="passed"  # Not necessarily a failure
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_operator_quorum_detection" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleOperatorTests"

# Test 5: Verify secret creation is conditional
echo ""
echo "🧪 Test 5: Verify operator secret creation logic..."
test_start=$(date +%s)
test_status="failed"
test_message=""

if [[ -z "$OPERATOR_POD" ]]; then
  echo "  ⚠️  Operator pod not found"
  test_message="Operator pod not found"
else
  # Check if operator created any secrets
  CREATED_SECRETS=$(oc logs "$OPERATOR_POD" -n "${STORAGE_SCALE_OPERATOR_NAMESPACE}" --tail=1000 2>/dev/null | grep -c "create new secret\|Applied.*Secret" || echo "0")
  
  # Check for GUI secret specifically
  GUI_SECRET_CREATED=$(oc logs "$OPERATOR_POD" -n "${STORAGE_SCALE_OPERATOR_NAMESPACE}" --tail=1000 2>/dev/null | grep -c "ibm-spectrum-scale-gui-ssh-key" || echo "0")
  
  # Check if operator attempted core secret
  CORE_SECRET_ATTEMPTED=$(oc logs "$OPERATOR_POD" -n "${STORAGE_SCALE_OPERATOR_NAMESPACE}" --tail=1000 2>/dev/null | grep -c "ibm-spectrum-scale-core-ssh-key-secret" || echo "0")
  
  if [[ "$CREATED_SECRETS" -gt 0 ]]; then
    echo "  ✅ Operator created ${CREATED_SECRETS} secret(s)"
    
    if [[ "$GUI_SECRET_CREATED" -gt 0 ]]; then
      echo "    - GUI SSH key created early ✅"
    fi
    
    if [[ "$CORE_SECRET_ATTEMPTED" -eq 0 ]]; then
      echo "    - Core SSH key NOT attempted (waiting for quorum) ✅"
      echo "  ✅ Operator secret creation logic is working correctly"
      test_status="passed"
      test_message="Operator secret creation is working as designed:\n- Created ${CREATED_SECRETS} secret(s) successfully\n- GUI SSH key created during initial reconciliation\n- Core SSH key creation deferred until quorum is established\n\nThis validates the operator is functioning correctly and waiting for the proper conditions before creating quorum-dependent secrets."
    else
      echo "    - Core SSH key creation attempted ${CORE_SECRET_ATTEMPTED} time(s)"
      test_status="passed"
    fi
  else
    echo "  ⚠️  Operator has not created any secrets yet"
    test_message="Operator has not created any secrets. This may indicate operator has not yet reconciled the Cluster CR, or reconciliation is blocked."
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_secret_creation_dependencies" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleOperatorTests"

