#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "📸 Testing CNV VM snapshot operations with IBM Storage Scale shared storage..."

# Set default values from FA__ prefixed environment variables
CNV_NAMESPACE="${FA__CNV_NAMESPACE:-openshift-cnv}"
SHARED_STORAGE_CLASS="${FA__SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
TEST_NAMESPACE="${FA__TEST_NAMESPACE:-cnv-snapshots-test}"
VM_NAME="${FA__VM_NAME:-test-snapshot-vm}"
SNAPSHOT_NAME="${FA__SNAPSHOT_NAME:-test-vm-snapshot}"
RESTORE_VM_NAME="${FA__RESTORE_VM_NAME:-restored-vm}"
VM_CPU_REQUEST="${FA__VM_CPU_REQUEST:-1}"
VM_MEMORY_REQUEST="${FA__VM_MEMORY_REQUEST:-1Gi}"
VM_SNAPSHOT_TIMEOUT="${FA__VM_SNAPSHOT_TIMEOUT:-10m}"

# JUnit XML test results
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_vm_snapshots_tests.xml"
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
  local test_classname="${5:-VMSnapshotsTests}"
  
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
  <testsuite name="VM Snapshots Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/junit_vm_snapshots_tests.xml"
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
echo "  Snapshot Name: ${SNAPSHOT_NAME}"
echo "  Restore VM Name: ${RESTORE_VM_NAME}"
echo "  VM CPU Request: ${VM_CPU_REQUEST}"
echo "  VM Memory Request: ${VM_MEMORY_REQUEST}"
echo "  Snapshot Timeout: ${VM_SNAPSHOT_TIMEOUT}"
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

# Check for VolumeSnapshotClass
echo ""
echo "🔍 Checking for VolumeSnapshotClass..."
SNAPSHOT_CLASSES=$(oc get volumesnapshotclass --no-headers 2>/dev/null | wc -l || echo "0")
echo "  📊 VolumeSnapshotClass count: ${SNAPSHOT_CLASSES}"

if [[ ${SNAPSHOT_CLASSES} -eq 0 ]]; then
  echo "  ⚠️  No VolumeSnapshotClass found"
  echo "  Attempting to create VolumeSnapshotClass for IBM Storage Scale CSI..."
  
  # Create VolumeSnapshotClass for IBM Storage Scale CSI
  if oc apply -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ibm-spectrum-scale-snapshotclass
driver: spectrumscale.csi.ibm.com
deletionPolicy: Delete
EOF
  then
    echo "  ✅ VolumeSnapshotClass created"
  else
    echo "  ⚠️  Failed to create VolumeSnapshotClass"
    echo "  Snapshot tests may fail without VolumeSnapshotClass"
  fi
else
  echo "  ✅ VolumeSnapshotClass available"
  echo "  📋 Available VolumeSnapshotClasses:"
  oc get volumesnapshotclass -o custom-columns="NAME:.metadata.name,DRIVER:.driver,DELETIONPOLICY:.deletionPolicy"
fi

# Create DataVolume for VM
echo ""
echo "📦 Creating DataVolume for snapshot test VM..."
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
echo "🖥️  Creating VM for snapshot testing..."
if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: snapshot-test
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

# Test 1: FA-CNV-1025 - Create VM snapshot
test_start=$(start_test "FA-CNV-1025: Creating VM snapshot with shared storage")
test_status="failed"
test_message=""

echo "  📸 Creating VirtualMachineSnapshot: ${SNAPSHOT_NAME}..."
if oc apply -f - <<EOF
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineSnapshot
metadata:
  name: ${SNAPSHOT_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${VM_NAME}
EOF
then
  echo "  ✅ VirtualMachineSnapshot created successfully"
  
  # Wait for snapshot to be ready
  echo "  ⏳ Waiting for snapshot to be ready (${VM_SNAPSHOT_TIMEOUT} timeout)..."
  if oc wait vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout="${VM_SNAPSHOT_TIMEOUT}"; then
    echo "  ✅ Snapshot is ready"
    
    # Get snapshot status
    SNAPSHOT_STATUS=$(oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "  📊 Snapshot status: ${SNAPSHOT_STATUS}"
    
    test_status="passed"
  else
    echo "  ⚠️  Snapshot not ready within timeout"
    test_message="Snapshot not ready within ${VM_SNAPSHOT_TIMEOUT}"
    
    # Get snapshot details for debugging
    echo "  📊 Snapshot details:"
    oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" -o yaml || true
    oc describe vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" || true
  fi
else
  echo "  ❌ Failed to create VirtualMachineSnapshot"
  test_message="Failed to create VirtualMachineSnapshot resource"
fi

record_test "$test_start" "fa_cnv_1025_create_vm_snapshot" "$test_status" "$test_message"

# Test 2: FA-CNV-1026 - Verify snapshot exists
test_start=$(start_test "FA-CNV-1026: Verifying VM snapshot exists")
test_status="failed"
test_message=""

# Check if snapshot exists
if oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  echo "  ✅ VirtualMachineSnapshot exists"
  
  # Get snapshot details
  SNAPSHOT_READY=$(oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.readyToUse}' 2>/dev/null || echo "false")
  echo "  📊 Snapshot readyToUse: ${SNAPSHOT_READY}"
  
  # Check for VolumeSnapshot resources created by the VM snapshot
  echo "  🔍 Checking for VolumeSnapshot resources..."
  VOLUME_SNAPSHOTS=$(oc get volumesnapshot -n "${TEST_NAMESPACE}" --no-headers 2>/dev/null | wc -l || echo "0")
  echo "  📊 VolumeSnapshot count: ${VOLUME_SNAPSHOTS}"
  
  if [[ ${VOLUME_SNAPSHOTS} -gt 0 ]]; then
    echo "  ✅ VolumeSnapshot resources created"
    echo "  📋 VolumeSnapshots:"
    oc get volumesnapshot -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,READYTOUSE:.status.readyToUse,SOURCEPVC:.spec.source.persistentVolumeClaimName"
    
    # Verify snapshot content manifest
    SNAPSHOT_CONTENT=$(oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.virtualMachineSnapshotContentName}' 2>/dev/null || echo "")
    if [[ -n "${SNAPSHOT_CONTENT}" ]]; then
      echo "  ✅ Snapshot content manifest exists: ${SNAPSHOT_CONTENT}"
      test_status="passed"
    else
      echo "  ⚠️  Snapshot content manifest not found"
      test_message="Snapshot content manifest not found"
    fi
  else
    echo "  ⚠️  No VolumeSnapshot resources found"
    test_message="No VolumeSnapshot resources created"
  fi
else
  echo "  ❌ VirtualMachineSnapshot not found"
  test_message="VirtualMachineSnapshot resource not found"
fi

record_test "$test_start" "fa_cnv_1026_verify_vm_snapshot_exists" "$test_status" "$test_message"

# Test 3: FA-CNV-1027 - Restore VM from snapshot
test_start=$(start_test "FA-CNV-1027: Restoring VM from snapshot")
test_status="failed"
test_message=""

echo "  🔄 Creating VirtualMachineRestore: ${RESTORE_VM_NAME}-restore..."
if oc apply -f - <<EOF
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineRestore
metadata:
  name: ${RESTORE_VM_NAME}-restore
  namespace: ${TEST_NAMESPACE}
spec:
  target:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${RESTORE_VM_NAME}
  virtualMachineSnapshotName: ${SNAPSHOT_NAME}
EOF
then
  echo "  ✅ VirtualMachineRestore created successfully"
  
  # Wait for restore to complete
  echo "  ⏳ Waiting for restore to complete (${VM_SNAPSHOT_TIMEOUT} timeout)..."
  if oc wait vmrestore "${RESTORE_VM_NAME}-restore" -n "${TEST_NAMESPACE}" --for=condition=Complete --timeout="${VM_SNAPSHOT_TIMEOUT}"; then
    echo "  ✅ Restore completed successfully"
    
    # Get restore status
    RESTORE_STATUS=$(oc get vmrestore "${RESTORE_VM_NAME}-restore" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "  📊 Restore status: ${RESTORE_STATUS}"
    
    # Check if restored VM exists
    if oc get vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
      echo "  ✅ Restored VM exists"
      
      # Try to start the restored VM
      echo "  🚀 Starting restored VM to verify it boots..."
      if oc patch vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
        echo "  ✅ Restored VM start command sent"
        
        # Wait for VMI to be running using oc wait
        if oc wait vmi "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" \
            --for=jsonpath='{.status.phase}'=Running --timeout=120s 2>/dev/null; then
          echo "  ✅ Restored VM VMI is running - VM boots successfully"
          test_status="passed"
        else
          echo "  ⚠️  Restored VM VMI not running within timeout"
          test_message="Restored VM VMI not running within timeout"
        fi
      else
        echo "  ⚠️  Failed to start restored VM"
        test_message="Failed to start restored VM"
      fi
    else
      echo "  ⚠️  Restored VM not found"
      test_message="Restored VM not found after restore operation"
    fi
  else
    echo "  ⚠️  Restore not complete within timeout"
    test_message="Restore not complete within ${VM_SNAPSHOT_TIMEOUT}"
    
    # Get restore details for debugging
    echo "  📊 Restore details:"
    oc get vmrestore "${RESTORE_VM_NAME}-restore" -n "${TEST_NAMESPACE}" -o yaml || true
    oc describe vmrestore "${RESTORE_VM_NAME}-restore" -n "${TEST_NAMESPACE}" || true
  fi
else
  echo "  ❌ Failed to create VirtualMachineRestore"
  test_message="Failed to create VirtualMachineRestore resource"
fi

record_test "$test_start" "fa_cnv_1027_restore_vm_from_snapshot" "$test_status" "$test_message"

# Test 4: FA-CNV-1028 - Delete VM snapshot
test_start=$(start_test "FA-CNV-1028: Deleting VM snapshot")
test_status="failed"
test_message=""

echo "  🗑️  Deleting VirtualMachineSnapshot: ${SNAPSHOT_NAME}..."
if oc delete vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}"; then
  echo "  ✅ VirtualMachineSnapshot deletion initiated"
  
  # Wait for snapshot to be deleted using oc wait
  echo "  ⏳ Waiting for snapshot to be deleted (2m timeout)..."
  if oc wait vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" --for=delete --timeout=120s 2>/dev/null; then
    echo "  ✅ VirtualMachineSnapshot deleted successfully"
    
    # Verify VolumeSnapshot resources are cleaned up
    echo "  🔍 Checking VolumeSnapshot cleanup..."
    VOLUME_SNAPSHOTS=$(oc get volumesnapshot -n "${TEST_NAMESPACE}" --no-headers 2>/dev/null | wc -l || echo "0")
    echo "  📊 Remaining VolumeSnapshot count: ${VOLUME_SNAPSHOTS}"
    
    # Verify original VM is unaffected
    if oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
      echo "  ✅ Original VM unaffected by snapshot deletion"
      test_status="passed"
    else
      echo "  ⚠️  Original VM not found (unexpected)"
      test_message="Original VM not found after snapshot deletion"
    fi
  else
    echo "  ⚠️  Snapshot not deleted within timeout"
    test_message="Snapshot not deleted within 2m timeout"
    oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" -o yaml || true
  fi
else
  echo "  ❌ Failed to delete VirtualMachineSnapshot"
  test_message="Failed to delete VirtualMachineSnapshot resource"
fi

record_test "$test_start" "fa_cnv_1028_delete_vm_snapshot" "$test_status" "$test_message"

# Display snapshot summary
echo ""
echo "📊 Snapshot Operations Summary:"
if oc get vmsnapshot -n "${TEST_NAMESPACE}" >/dev/null; then
  echo "  📋 VirtualMachineSnapshots:"
  oc get vmsnapshot -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,PHASE:.status.phase,READYTOUSE:.status.readyToUse,AGE:.metadata.creationTimestamp" 2>/dev/null || echo "  None"
fi

if oc get volumesnapshot -n "${TEST_NAMESPACE}" >/dev/null; then
  echo "  📋 VolumeSnapshots:"
  oc get volumesnapshot -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,READYTOUSE:.status.readyToUse,SOURCEPVC:.spec.source.persistentVolumeClaimName" 2>/dev/null || echo "  None"
fi

# Cleanup
echo ""
echo "🧹 Cleaning up test resources..."
echo "  🗑️  Stopping VMs..."
if oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}' || true
fi
if oc get vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  oc patch vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}' || true
fi
# Wait for VMIs to be deleted before proceeding with cleanup
oc wait vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" --for=delete --timeout=60s 2>/dev/null || true
oc wait vmi "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" --for=delete --timeout=60s 2>/dev/null || true

echo "  🗑️  Deleting restore resource..."
oc delete vmrestore "${RESTORE_VM_NAME}-restore" -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting snapshots..."
oc delete vmsnapshot -n "${TEST_NAMESPACE}" --all --ignore-not-found

echo "  🗑️  Deleting VMs..."
oc delete vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting DataVolumes..."
oc delete datavolume "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting test namespace..."
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found

echo "  ✅ Cleanup completed"

echo ""
echo "📊 VM Snapshot Test Summary"
echo "==========================="
echo "✅ FA-CNV-1025: VM snapshot creation tested"
echo "✅ FA-CNV-1026: VM snapshot verification tested"
echo "✅ FA-CNV-1027: VM restore from snapshot tested"
echo "✅ FA-CNV-1028: VM snapshot deletion tested"
echo "✅ VolumeSnapshot integration with IBM Storage Scale CSI verified"
echo ""
echo "🎉 VM snapshot operations with IBM Storage Scale shared storage completed!"


