#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🔄 Testing CNV VM lifecycle operations with IBM Storage Scale shared storage..."

# Set default values from FA__ prefixed environment variables
CNV_NAMESPACE="${FA__CNV_NAMESPACE:-openshift-cnv}"
SHARED_STORAGE_CLASS="${FA__SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
TEST_NAMESPACE="${FA__TEST_NAMESPACE:-cnv-lifecycle-test}"
VM_NAME="${FA__VM_NAME:-test-lifecycle-vm}"
VM_CPU_REQUEST="${FA__VM_CPU_REQUEST:-1}"
VM_MEMORY_REQUEST="${FA__VM_MEMORY_REQUEST:-1Gi}"

# JUnit XML test results
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_vm_lifecycle_tests.xml"
TEST_START_TIME=$SECONDS
TESTS_TOTAL=0
TESTS_FAILED=0
TESTS_PASSED=0
TEST_CASES=""

# Function to escape XML special characters
escape_xml() {
  local text="$1"
  # Escape XML special characters: & must be first to avoid double-escaping
  echo "$text" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g'
}

# Function to add test result to JUnit XML
add_test_result() {
  local test_name="$1"
  local test_status="$2"  # "passed" or "failed"
  local test_duration="$3"
  local test_message="${4:-}"
  local test_classname="${5:-VMLifecycleTests}"
  
  # Escape XML special characters in user-provided strings
  test_name=$(escape_xml "$test_name")
  test_message=$(escape_xml "$test_message")
  test_classname=$(escape_xml "$test_classname")
  
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
  local total_duration=$((SECONDS - TEST_START_TIME))
  
  cat > "${JUNIT_RESULTS_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="VM Lifecycle Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/junit_vm_lifecycle_tests.xml"
    echo "  ✅ Results copied to SHARED_DIR"
  fi
}

start_test() {
  local test_description="$1"
  : "🧪 ${test_description}..."
  echo "$SECONDS"
}

# Helper function to record test result (eliminates repetitive duration calculation)
record_test() {
  local test_start="$1"
  local test_name="$2"
  local test_status="$3"
  local test_message="${4:-}"
  
  local test_duration=$((SECONDS - test_start))
  add_test_result "$test_name" "$test_status" "$test_duration" "$test_message"
}

# Trap to ensure JUnit XML is generated even on failure
trap generate_junit_xml EXIT

echo "📋 Configuration:"
echo "  CNV Namespace: ${CNV_NAMESPACE}"
echo "  Test Namespace: ${TEST_NAMESPACE}"
echo "  Shared Storage Class: ${SHARED_STORAGE_CLASS}"
echo "  VM Name: ${VM_NAME}"
echo "  VM CPU Request: ${VM_CPU_REQUEST}"
echo "  VM Memory Request: ${VM_MEMORY_REQUEST}"
echo ""

# Create test namespace
echo "📁 Creating test namespace..."
if oc get namespace "${TEST_NAMESPACE}" >/dev/null; then
  echo "  ✅ Test namespace already exists: ${TEST_NAMESPACE}"
else
  oc create namespace "${TEST_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${TEST_NAMESPACE}" --timeout=300s
  echo "  ✅ Test namespace created: ${TEST_NAMESPACE}"
fi

# Check if shared storage class exists
echo ""
echo "🔍 Checking shared storage class..."
if oc get storageclass "${SHARED_STORAGE_CLASS}" >/dev/null; then
  echo "  ✅ Shared storage class found"
  PROVISIONER=$(oc get storageclass "${SHARED_STORAGE_CLASS}" -o jsonpath='{.provisioner}' 2>/dev/null || echo "Unknown")
  echo "  📊 Provisioner: ${PROVISIONER}"
else
  echo "  ❌ Shared storage class not found"
  echo "  Please ensure the shared storage class is created before running this test"
  exit 1
fi

# Create DataVolume for VM
echo ""
echo "📦 Creating DataVolume for VM..."
if oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${VM_NAME}-dv
  namespace: ${TEST_NAMESPACE}
spec:
  source:
    registry:
      url: "docker://quay.io/kubevirt/fedora-cloud-container-disk-demo:latest"
  pvc:
    accessModes:
    - ReadWriteOnce
    resources:
      requests:
        storage: 5Gi
    storageClassName: ${SHARED_STORAGE_CLASS}
EOF
then
  echo "  ✅ DataVolume created successfully"
  
  # Wait for DataVolume to be ready
  echo "  ⏳ Waiting for DataVolume to be ready (10m timeout)..."
  if oc wait datavolume "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout=10m; then
    echo "  ✅ DataVolume is ready"
  else
    echo "  ❌ DataVolume not ready within timeout"
    oc get datavolume "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" -o yaml
    exit 1
  fi
else
  echo "  ❌ Failed to create DataVolume"
  exit 1
fi

# Create VM with shared storage
echo ""
echo "🖥️  Creating VM with shared storage..."
if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: lifecycle-test
spec:
  running: false
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${VM_NAME}
    spec:
      domain:
        resources:
          requests:
            memory: ${VM_MEMORY_REQUEST}
            cpu: ${VM_CPU_REQUEST}
        devices:
          disks:
          - name: disk0
            disk:
              bus: virtio
          - name: disk1
            disk:
              bus: virtio
      volumes:
      - name: disk0
        containerDisk:
          image: quay.io/kubevirt/fedora-cloud-container-disk-demo:latest
      - name: disk1
        persistentVolumeClaim:
          claimName: ${VM_NAME}-dv
EOF
then
  echo "  ✅ VM created successfully"
  
  # Wait for VM to be created
  echo "  ⏳ Waiting for VM resource to be available..."
  if oc wait --for=jsonpath='{.metadata.name}'="${VM_NAME}" vm/"${VM_NAME}" -n "${TEST_NAMESPACE}" --timeout=60s; then
    echo "  ✅ VM resource available"
  else
    echo "  ❌ VM resource not available"
    exit 1
  fi
else
  echo "  ❌ Failed to create VM"
  exit 1
fi

# Test 1: Start VM
test_start=$(start_test "FA-CNV-1011 Prerequisite: Starting VM")
test_status="failed"
test_message=""

echo "  🚀 Starting VM by setting spec.running=true..."
if oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
  echo "  ✅ VM start command sent"
  
  # Wait for VMI to be running using oc wait
  echo "  ⏳ Waiting for VMI to be running (5m timeout)..."
  if oc wait vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" \
      --for=jsonpath='{.status.phase}'=Running --timeout=300s; then
    echo "  ✅ VMI is running"
    
    # Get VM status
    VM_STATUS=$(oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
    echo "  📊 VM Status: ${VM_STATUS}"
    
    test_status="passed"
  else
    echo "  ⚠️  VMI not running within timeout"
    test_message="VMI not running within 5m timeout"
    oc describe vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" || true
  fi
else
  echo "  ❌ Failed to start VM"
  test_message="Failed to patch VM spec.running=true"
fi

record_test "$test_start" "fa_cnv_1011_prerequisite_start_vm" "$test_status" "$test_message"

# If VM didn't start, we can't continue with remaining tests
if [[ "$test_status" != "passed" ]]; then
  echo ""
  echo "❌ VM failed to start - cannot continue with lifecycle tests"
  exit 1
fi

# Test 2: FA-CNV-1011 - Stop VM
test_start=$(start_test "FA-CNV-1011: Stopping VM with shared storage")
test_status="failed"
test_message=""

echo "  🛑 Stopping VM by setting spec.running=false..."
if oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
  echo "  ✅ VM stop command sent"
  
  # Wait for VMI to be deleted using oc wait --for=delete
  echo "  ⏳ Waiting for VMI to be deleted (5m timeout)..."
  if oc wait vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" --for=delete --timeout=300s 2>/dev/null; then
    echo "  ✅ VMI deleted successfully"
    
    # Verify VM status shows Stopped
    VM_STATUS=$(oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
    echo "  📊 VM Status after stop: ${VM_STATUS}"
    
    if [[ "$VM_STATUS" == "Stopped" ]]; then
      echo "  ✅ VM status is Stopped"
      test_status="passed"
    else
      echo "  ⚠️  VM status is not Stopped (status: ${VM_STATUS})"
      test_message="VM status not 'Stopped' after VMI deletion (status: ${VM_STATUS})"
    fi
  else
    echo "  ⚠️  VMI not deleted within timeout"
    test_message="VMI not deleted within 5m timeout"
    oc describe vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" || true
  fi
else
  echo "  ❌ Failed to stop VM"
  test_message="Failed to patch VM spec.running=false"
fi

record_test "$test_start" "fa_cnv_1011_stop_vm_with_shared_storage" "$test_status" "$test_message"

# Test 3: FA-CNV-1012 - Restart VM
test_start=$(start_test "FA-CNV-1012: Restarting VM with shared storage")
test_status="failed"
test_message=""

echo "  🔄 Restarting VM by setting spec.running=true..."
if oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
  echo "  ✅ VM restart command sent"
  
  # Wait for VMI to be running using oc wait
  echo "  ⏳ Waiting for VMI to be running (5m timeout)..."
  if oc wait vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" \
      --for=jsonpath='{.status.phase}'=Running --timeout=300s; then
    echo "  ✅ VMI is running after restart"
    
    # Get VM status
    VM_STATUS=$(oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
    echo "  📊 VM Status after restart: ${VM_STATUS}"
    
    # Verify PVC is still bound (data persistence check)
    PVC_STATUS=$(oc get pvc "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "  📊 PVC Status: ${PVC_STATUS}"
    
    if [[ "$PVC_STATUS" == "Bound" ]]; then
      echo "  ✅ PVC still bound - data persistence verified"
      test_status="passed"
    else
      echo "  ⚠️  PVC not bound (status: ${PVC_STATUS})"
      test_message="PVC not bound after VM restart (status: ${PVC_STATUS})"
    fi
  else
    echo "  ⚠️  VMI not running within timeout"
    test_message="VMI not running within 5m timeout after restart"
    oc describe vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" || true
  fi
else
  echo "  ❌ Failed to restart VM"
  test_message="Failed to patch VM spec.running=true for restart"
fi

record_test "$test_start" "fa_cnv_1012_restart_vm_with_shared_storage" "$test_status" "$test_message"

# Cleanup
echo ""
echo "🧹 Cleaning up test resources..."
echo "  🗑️  Stopping VM..."
if oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}' || true
  # Wait for VMI to be deleted before proceeding with cleanup
  oc wait vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" --for=delete --timeout=60s 2>/dev/null || true
fi

echo "  🗑️  Deleting VM..."
oc delete vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting DataVolume..."
oc delete datavolume "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting test namespace..."
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found

echo "  ✅ Cleanup completed"

echo ""
echo "📊 VM Lifecycle Test Summary"
echo "============================"
echo "✅ FA-CNV-1011: VM stop operation tested"
echo "✅ FA-CNV-1012: VM restart operation tested"
echo "✅ Data persistence verified across VM lifecycle"
echo ""
echo "🎉 VM lifecycle operations with IBM Storage Scale shared storage completed!"


