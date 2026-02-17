#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Testing CNV VM snapshot operations with IBM Storage Scale shared storage'

# Set default values
FA__CNV__NAMESPACE="${FA__CNV__NAMESPACE:-openshift-cnv}"
FA__CNV__SHARED_STORAGE_CLASS="${FA__CNV__SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
FA__CNV__TEST_NAMESPACE="${FA__CNV__TEST_NAMESPACE:-cnv-snapshots-test}"
FA__CNV__VM_NAME="${FA__CNV__VM_NAME:-test-snapshot-vm}"
FA__CNV__SNAPSHOT_NAME="${FA__CNV__SNAPSHOT_NAME:-test-vm-snapshot}"
FA__CNV__RESTORE_VM_NAME="${FA__CNV__RESTORE_VM_NAME:-restored-vm}"
FA__CNV__VM_CPU_REQUEST="${FA__CNV__VM_CPU_REQUEST:-1}"
FA__CNV__VM_MEMORY_REQUEST="${FA__CNV__VM_MEMORY_REQUEST:-1Gi}"
FA__CNV__VM_SNAPSHOT_TIMEOUT="${FA__CNV__VM_SNAPSHOT_TIMEOUT:-25m}"

# JUnit XML test results
junitResultsFile="${ARTIFACT_DIR}/junit_vm_snapshots_tests.xml"
testStartTime=$SECONDS
testsTotal=0
testsFailed=0
testsPassed=0
testCases=""

# Function to escape XML special characters
EscapeXml() {
  typeset text="${1}"; (($#)) && shift
  # Escape XML special characters: & must be first to avoid double-escaping
  echo "$text" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g'

  true
}

# Function to add test result to JUnit XML
AddTestResult() {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift  # "passed" or "failed"
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-VMSnapshotsTests}"; (($#)) && shift
  
  # Escape XML special characters in user-provided strings
  testName=$(EscapeXml "$testName")
  testMessage=$(EscapeXml "$testMessage")
  testClassName=$(EscapeXml "$testClassName")
  
  testsTotal=$((testsTotal + 1))
  
  if [[ "$testStatus" == "passed" ]]; then
    testsPassed=$((testsPassed + 1))
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\"/>"
  else
    testsFailed=$((testsFailed + 1))
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${testMessage}</failure>
    </testcase>"
  fi

  true
}

# Function to generate JUnit XML report
GenerateJunitXml() {
  typeset totalDuration=$((SECONDS - testStartTime))
  
  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="VM Snapshots Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : "Test Results Summary: Total=${testsTotal} Passed=${testsPassed} Failed=${testsFailed} Duration=${totalDuration}s Results=${junitResultsFile}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_vm_snapshots_tests.xml"
    : 'Results copied to SHARED_DIR'
  fi

  true
}

StartTest() {
  typeset testDescription="${1}"; (($#)) && shift
  : "🧪 ${testDescription}..."
  echo "$SECONDS"

  true
}

# Helper function to record test result (eliminates repetitive duration calculation)
RecordTest() {
  typeset testStart="${1}"; (($#)) && shift
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  
  typeset testDuration=$((SECONDS - testStart))
  AddTestResult "$testName" "$testStatus" "$testDuration" "$testMessage"

  true
}

# Trap to ensure JUnit XML is generated even on failure
trap GenerateJunitXml EXIT

: "Configuration: CNV_NS=${FA__CNV__NAMESPACE} TEST_NS=${FA__CNV__TEST_NAMESPACE} SC=${FA__CNV__SHARED_STORAGE_CLASS} VM=${FA__CNV__VM_NAME} SNAP=${FA__CNV__SNAPSHOT_NAME} RESTORE=${FA__CNV__RESTORE_VM_NAME} CPU=${FA__CNV__VM_CPU_REQUEST} MEM=${FA__CNV__VM_MEMORY_REQUEST} TIMEOUT=${FA__CNV__VM_SNAPSHOT_TIMEOUT}"

# Create test namespace
: 'Creating test namespace'
if oc get namespace "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  : "Test namespace already exists: ${FA__CNV__TEST_NAMESPACE}"
else
  oc create namespace "${FA__CNV__TEST_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  oc wait --for=jsonpath='{.status.phase}'=Active namespace/"${FA__CNV__TEST_NAMESPACE}" --timeout=300s
  : "Test namespace created: ${FA__CNV__TEST_NAMESPACE}"
fi

# Check if shared storage class exists
: 'Checking shared storage class'
if oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" >/dev/null; then
  : 'Shared storage class found'
  provisioner=$(oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" -o jsonpath='{.provisioner}')
  : "Provisioner: ${provisioner}"
else
  : 'Shared storage class not found - ensure it is created before running this test'
  exit 1
fi

# Check for VolumeSnapshotClass
: 'Checking for VolumeSnapshotClass'
snapshotClasses=$(oc get volumesnapshotclass --no-headers | wc -l)
: "VolumeSnapshotClass count: ${snapshotClasses}"

if [[ ${snapshotClasses} -eq 0 ]]; then
  : 'No VolumeSnapshotClass found - attempting to create for IBM Storage Scale CSI'
  
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
    : 'VolumeSnapshotClass created'
  else
    : 'Failed to create VolumeSnapshotClass - snapshot tests may fail'
  fi
else
  : 'VolumeSnapshotClass available'
  : 'Available VolumeSnapshotClasses'
  oc get volumesnapshotclass -o custom-columns="NAME:.metadata.name,DRIVER:.driver,DELETIONPOLICY:.deletionPolicy"
fi

# Create DataVolume for VM
: 'Creating DataVolume for snapshot test VM'
if oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${FA__CNV__VM_NAME}-dv
  namespace: ${FA__CNV__TEST_NAMESPACE}
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
    storageClassName: ${FA__CNV__SHARED_STORAGE_CLASS}
EOF
then
  : 'DataVolume created successfully'
  
  # Wait for DataVolume to be ready
  : 'Waiting for DataVolume to be ready (10m timeout)'
  if oc wait datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=10m; then
    : 'DataVolume is ready'
  else
    : 'DataVolume not ready within timeout'
    oc get datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml
    exit 1
  fi
else
  : 'Failed to create DataVolume'
  exit 1
fi

# Create VM with shared storage
: 'Creating VM for snapshot testing'
if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${FA__CNV__VM_NAME}
  namespace: ${FA__CNV__TEST_NAMESPACE}
  labels:
    app: snapshot-test
spec:
  running: false
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${FA__CNV__VM_NAME}
    spec:
      domain:
        resources:
          requests:
            memory: ${FA__CNV__VM_MEMORY_REQUEST}
            cpu: ${FA__CNV__VM_CPU_REQUEST}
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
          claimName: ${FA__CNV__VM_NAME}-dv
EOF
then
  : 'VM created successfully'
  
  # Wait for VM to be created
  : 'Waiting for VM resource to be available'
  if oc wait --for=jsonpath='{.metadata.name}'="${FA__CNV__VM_NAME}" vm/"${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --timeout=60s; then
    : 'VM resource available'
  else
    : 'VM resource not available'
    exit 1
  fi
else
  : 'Failed to create VM'
  exit 1
fi

# Test 1: FA-CNV-1025 - Create VM snapshot
testStart=$(StartTest "FA-CNV-1025: Creating VM snapshot with shared storage")
testStatus="failed"
testMessage=""

: "Creating VirtualMachineSnapshot: ${FA__CNV__SNAPSHOT_NAME}"
if oc apply -f - <<EOF
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineSnapshot
metadata:
  name: ${FA__CNV__SNAPSHOT_NAME}
  namespace: ${FA__CNV__TEST_NAMESPACE}
spec:
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${FA__CNV__VM_NAME}
EOF
then
  : 'VirtualMachineSnapshot created successfully'
  
  # Wait for snapshot to be ready
  : "Waiting for snapshot to be ready (${FA__CNV__VM_SNAPSHOT_TIMEOUT} timeout)"
  if oc wait vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout="${FA__CNV__VM_SNAPSHOT_TIMEOUT}"; then
    : 'Snapshot is ready'
    
    # Get snapshot status
    snapshotStatus=$(oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')
    : "Snapshot status: ${snapshotStatus}"
    
    testStatus="passed"
  else
    : 'Snapshot not ready within timeout'
    testMessage="Snapshot not ready within ${FA__CNV__VM_SNAPSHOT_TIMEOUT}"
    
    # Get snapshot details for debugging
    : 'Snapshot details'
    if ! oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml; then
      : 'snapshot details not available'
    fi
    if ! oc describe vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      : 'snapshot description not available'
    fi
  fi
else
  : 'Failed to create VirtualMachineSnapshot'
  testMessage="Failed to create VirtualMachineSnapshot resource"
fi

RecordTest "$testStart" "fa_cnv_1025_create_vm_snapshot" "$testStatus" "$testMessage"

# Test 2: FA-CNV-1026 - Verify snapshot exists
testStart=$(StartTest "FA-CNV-1026: Verifying VM snapshot exists")
testStatus="failed"
testMessage=""

# Check if snapshot exists
if oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  : 'VirtualMachineSnapshot exists'
  
  # Get snapshot details
  snapshotReady=$(oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.readyToUse}')
  : "Snapshot readyToUse: ${snapshotReady}"
  
  # Check for VolumeSnapshot resources created by the VM snapshot
  : 'Checking for VolumeSnapshot resources'
  volumeSnapshots=$(oc get volumesnapshot -n "${FA__CNV__TEST_NAMESPACE}" --no-headers | wc -l)
  : "VolumeSnapshot count: ${volumeSnapshots}"
  
  if [[ ${volumeSnapshots} -gt 0 ]]; then
    : 'VolumeSnapshot resources created'
    : 'VolumeSnapshots'
    oc get volumesnapshot -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,READYTOUSE:.status.readyToUse,SOURCEPVC:.spec.source.persistentVolumeClaimName"
    
    # Verify snapshot content manifest
    snapshotContent=$(oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.virtualMachineSnapshotContentName}')
    if [[ -n "${snapshotContent}" ]]; then
      : "Snapshot content manifest exists: ${snapshotContent}"
      testStatus="passed"
    else
      : 'Snapshot content manifest not found'
      testMessage="Snapshot content manifest not found"
    fi
  else
    : 'No VolumeSnapshot resources found'
    testMessage="No VolumeSnapshot resources created"
  fi
else
  : 'VirtualMachineSnapshot not found'
  testMessage="VirtualMachineSnapshot resource not found"
fi

RecordTest "$testStart" "fa_cnv_1026_verify_vm_snapshot_exists" "$testStatus" "$testMessage"

# Test 3: FA-CNV-1027 - Restore VM from snapshot
testStart=$(StartTest "FA-CNV-1027: Restoring VM from snapshot")
testStatus="failed"
testMessage=""

: "Creating VirtualMachineRestore: ${FA__CNV__RESTORE_VM_NAME}-restore"
if oc apply -f - <<EOF
apiVersion: snapshot.kubevirt.io/v1beta1
kind: VirtualMachineRestore
metadata:
  name: ${FA__CNV__RESTORE_VM_NAME}-restore
  namespace: ${FA__CNV__TEST_NAMESPACE}
spec:
  target:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: ${FA__CNV__RESTORE_VM_NAME}
  virtualMachineSnapshotName: ${FA__CNV__SNAPSHOT_NAME}
EOF
then
  : 'VirtualMachineRestore created successfully'
  
  # Wait for restore to complete
  : "Waiting for restore to complete (${FA__CNV__VM_SNAPSHOT_TIMEOUT} timeout)"
  if oc wait vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout="${FA__CNV__VM_SNAPSHOT_TIMEOUT}"; then
    : 'Restore completed successfully'
    
    # Get restore status
    restoreStatus=$(oc get vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')
    : "Restore status: ${restoreStatus}"
    
    # Check if restored VM exists
    if oc get vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
      : 'Restored VM exists'
      
      # Try to start the restored VM
      : 'Starting restored VM to verify it boots'
      if oc patch vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
        : 'Restored VM start command sent'
        
        vmiFound=false
        if oc wait --for=jsonpath='{.status.phase}'=Running \
            vmi/"${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --timeout=120s; then
          vmiFound=true
        fi
        
        if [[ "$vmiFound" == "true" ]]; then
          : 'Restored VM VMI created - VM boots successfully'
          testStatus="passed"
        else
          : 'Restored VM VMI not created'
          testMessage="Restored VM VMI not created within timeout"
        fi
      else
        : 'Failed to start restored VM'
        testMessage="Failed to start restored VM"
      fi
    else
      : 'Restored VM not found'
      testMessage="Restored VM not found after restore operation"
    fi
  else
    : 'Restore not complete within timeout'
    testMessage="Restore not complete within ${FA__CNV__VM_SNAPSHOT_TIMEOUT}"
    
    # Get restore details for debugging
    : 'Restore details'
    if ! oc get vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml; then
      : 'restore details not available'
    fi
    if ! oc describe vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}"; then
      : 'restore description not available'
    fi
  fi
else
  : 'Failed to create VirtualMachineRestore'
  testMessage="Failed to create VirtualMachineRestore resource"
fi

RecordTest "$testStart" "fa_cnv_1027_restore_vm_from_snapshot" "$testStatus" "$testMessage"

# Test 4: FA-CNV-1028 - Delete VM snapshot
testStart=$(StartTest "FA-CNV-1028: Deleting VM snapshot")
testStatus="failed"
testMessage=""

: "Deleting VirtualMachineSnapshot: ${FA__CNV__SNAPSHOT_NAME}"
if oc delete vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
  : 'VirtualMachineSnapshot deletion initiated'
  
  # Wait for snapshot to be deleted
  : 'Waiting for snapshot to be deleted (2m timeout)'
  SNAPSHOT_DELETED=false
  if oc wait --for=delete \
      vmsnapshot/"${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --timeout=120s; then
    SNAPSHOT_DELETED=true
  fi
  
  if [[ "$SNAPSHOT_DELETED" == "true" ]]; then
    : 'VirtualMachineSnapshot deleted successfully'
    
    # Verify VolumeSnapshot resources are cleaned up
    : 'Checking VolumeSnapshot cleanup'
    volumeSnapshots=$(oc get volumesnapshot -n "${FA__CNV__TEST_NAMESPACE}" --no-headers | wc -l)
    : "Remaining VolumeSnapshot count: ${volumeSnapshots}"
    
    # Verify original VM is unaffected
    if oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
      : 'Original VM unaffected by snapshot deletion'
      testStatus="passed"
    else
      : 'Original VM not found (unexpected)'
      testMessage="Original VM not found after snapshot deletion"
    fi
  else
    : 'Snapshot not deleted within timeout'
    testMessage="Snapshot not deleted within 2m timeout"
    if ! oc get vmsnapshot "${FA__CNV__SNAPSHOT_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml; then
      : 'snapshot details not available'
    fi
  fi
else
  : 'Failed to delete VirtualMachineSnapshot'
  testMessage="Failed to delete VirtualMachineSnapshot resource"
fi

RecordTest "$testStart" "fa_cnv_1028_delete_vm_snapshot" "$testStatus" "$testMessage"

# Display snapshot summary
: 'Snapshot Operations Summary'
if oc get vmsnapshot -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  : 'VirtualMachineSnapshots'
  if ! oc get vmsnapshot -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,PHASE:.status.phase,READYTOUSE:.status.readyToUse,AGE:.metadata.creationTimestamp"; then
    : 'no snapshots found'
  fi
fi

if oc get volumesnapshot -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  : 'VolumeSnapshots'
  if ! oc get volumesnapshot -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,READYTOUSE:.status.readyToUse,SOURCEPVC:.spec.source.persistentVolumeClaimName"; then
    : 'no volume snapshots found'
  fi
fi

# Cleanup
: 'Cleaning up test resources'
: 'Stopping VMs'
if oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  if ! oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
    : 'VM may already be stopped'
  fi
fi
if oc get vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  if ! oc patch vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
    : 'restored VM may already be stopped'
  fi
fi
oc delete vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete vmi "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting restore resource'
oc delete vmrestore "${FA__CNV__RESTORE_VM_NAME}-restore" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting snapshots'
oc delete vmsnapshot -n "${FA__CNV__TEST_NAMESPACE}" --all --ignore-not-found

: 'Deleting VMs'
oc delete vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete vm "${FA__CNV__RESTORE_VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting DataVolumes'
oc delete datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting test namespace'
oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Cleanup completed'

: 'VM snapshot operations with IBM Storage Scale shared storage completed'

true
