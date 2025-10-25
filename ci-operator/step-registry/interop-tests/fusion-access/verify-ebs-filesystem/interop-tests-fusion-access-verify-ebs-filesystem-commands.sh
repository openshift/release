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
  
  # Exit with failure if any tests failed
  if [[ ${TESTS_FAILED} -gt 0 ]]; then
    echo ""
    echo "❌ Test suite failed: ${TESTS_FAILED} test(s) failed"
    exit 1
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

# Test 4: Verify quorum dependency for filesystem
echo ""
echo "🧪 Test 4: Check if filesystem is blocked by quorum..."
test_start=$(date +%s)
test_status="failed"
test_message=""

# Get filesystem status message
FS_MESSAGE=$(oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} \
  -o jsonpath='{.status.conditions[?(@.type=="Success")].message}' 2>/dev/null || echo "Unknown")

# Check if "ongoing" in message (indicates waiting)
if echo "$FS_MESSAGE" | grep -qi "ongoing"; then
  echo "  ⚠️  SYMPTOM: Filesystem creation is ongoing (waiting for quorum)"
  echo "    Message: ${FS_MESSAGE}"
  test_message="⚠️ SYMPTOM: Filesystem stuck in 'ongoing' state.\nMessage: ${FS_MESSAGE}\n\nREASON: Filesystem creation requires quorum to be established.\nQuorum requires daemon pods to be in Running state.\nIf daemon pods are failing (check cluster verification), filesystem will remain in ongoing state.\n\nThis is NOT the root cause - fix daemon pod failures first."
elif [[ "${SUCCESS_STATUS}" == "True" ]]; then
  echo "  ✅ Filesystem created successfully"
  test_status="passed"
elif [[ "${SUCCESS_STATUS}" == "False" ]] && ! echo "$FS_MESSAGE" | grep -qi "ongoing"; then
  echo "  ❌ Filesystem failed: ${FS_MESSAGE}"
  test_message="Filesystem creation failed with message: ${FS_MESSAGE}"
else
  echo "  ℹ️  Filesystem status: ${SUCCESS_STATUS}"
  test_status="passed"  # Unknown status is not a hard failure
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_filesystem_quorum_dependency" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleFilesystemTests"

# Test 5: Verify LocalDisk resources status
echo ""
echo "🧪 Test 5: Check LocalDisk resources status..."
test_start=$(date +%s)
test_status="failed"
test_message=""

# Get LocalDisk resources
LOCALDISKS=$(oc get localdisk -n ${STORAGE_SCALE_NAMESPACE} -o name 2>/dev/null || echo "")

if [[ -z "$LOCALDISKS" ]]; then
  echo "  ⚠️  No LocalDisk resources found"
  test_message="No LocalDisk resources found in namespace ${STORAGE_SCALE_NAMESPACE}"
else
  LOCALDISK_COUNT=$(echo "$LOCALDISKS" | wc -w)
  READY_COUNT=0
  WAITING_COUNT=0
  
  for disk in $LOCALDISKS; do
    disk_name=$(basename "$disk")
    READY=$(oc get "$disk" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
    
    if [[ "$READY" == "true" ]]; then
      READY_COUNT=$((READY_COUNT + 1))
    else
      WAITING_COUNT=$((WAITING_COUNT + 1))
    fi
  done
  
  echo "  LocalDisk status: ${READY_COUNT} ready, ${WAITING_COUNT} waiting (total: ${LOCALDISK_COUNT})"
  
  if [[ $READY_COUNT -eq $LOCALDISK_COUNT ]]; then
    echo "  ✅ All LocalDisk resources are ready"
    test_status="passed"
  elif [[ $READY_COUNT -gt 0 ]]; then
    echo "  ⚠️  Partial LocalDisk readiness: ${READY_COUNT}/${LOCALDISK_COUNT}"
    test_message="⚠️ ${READY_COUNT} of ${LOCALDISK_COUNT} LocalDisk resources are ready.\nPartial readiness may indicate ongoing initialization.\nLocalDisk reconciliation depends on quorum establishment."
    test_status="passed"  # Partial is acceptable
  else
    echo "  ⚠️  SYMPTOM: No LocalDisk resources ready (waiting for quorum)"
    test_message="⚠️ SYMPTOM: LocalDisk resources are not ready.\nREASON: LocalDisk controller requires quorum pods to reconcile.\nIf daemon pods are not running (check cluster verification), LocalDisk will remain not ready.\n\nThis is a downstream symptom of daemon pod failures."
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_localdisk_resources_status" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleFilesystemTests"

# Test 6: Check operator reconciliation errors for filesystem
echo ""
echo "🧪 Test 6: Check operator reconciliation status for filesystem..."
test_start=$(date +%s)
test_status="failed"
test_message=""

# Get operator pod
OPERATOR_POD=$(oc get pods -n ibm-spectrum-scale-operator -l app.kubernetes.io/name=ibm-spectrum-scale-operator -o name 2>/dev/null | head -1 || echo "")

if [[ -z "$OPERATOR_POD" ]]; then
  echo "  ⚠️  Operator pod not found"
  test_message="IBM Spectrum Scale operator pod not found"
else
  # Check for "no quorum pods" errors in recent operator logs
  NO_QUORUM_ERRORS=$(oc logs "$OPERATOR_POD" -n ibm-spectrum-scale-operator --tail=500 2>/dev/null | grep -c "no quorum pods" || echo "0")
  
  if [[ "$NO_QUORUM_ERRORS" -eq 0 ]]; then
    echo "  ✅ No quorum-related errors in operator logs"
    test_status="passed"
  elif [[ "$NO_QUORUM_ERRORS" -lt 10 ]]; then
    echo "  ℹ️  Found ${NO_QUORUM_ERRORS} 'no quorum pods' messages (transient)"
    test_message="Found ${NO_QUORUM_ERRORS} 'no quorum pods' errors in operator logs.\nThis may indicate transient quorum establishment issues.\nOperator will retry reconciliation automatically."
    test_status="passed"  # Small number is acceptable
  else
    echo "  ⚠️  SYMPTOM: Operator shows ${NO_QUORUM_ERRORS} 'no quorum pods' errors"
    test_message="⚠️ SYMPTOM: Operator reports 'no quorum pods' error ${NO_QUORUM_ERRORS} times.\n\nREASON: Operator cannot reconcile Filesystem/LocalDisk without quorum.\nQuorum requires daemon pods to be in Running state.\n\nOPERATOR STATUS: Working correctly - waiting for quorum to form.\nACTION NEEDED: Fix daemon pod failures (check cluster verification Test 4).\n\nThis is NOT an operator bug - this is expected behavior when quorum cannot form."
  fi
fi

test_duration=$(($(date +%s) - test_start))
add_test_result "test_operator_reconciliation_errors" "$test_status" "$test_duration" "$test_message" "IBMStorageScaleFilesystemTests"
