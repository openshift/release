#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

eval "$(curl -fsSL \
    https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/\
libs/bash/ci-operator/interop/common/TestReport--JunitXml.sh
)"

LP_IO__TR__RESULTS_FILE="${ARTIFACT_DIR}/junit_vm_snapshots_tests.xml"
LP_IO__TR__SUITE_NAME="VM Snapshots Tests"
LP_IO__TR__START_TIME="${SECONDS}"
trap 'TestReport--GenerateJunitXml' EXIT

CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
SHARED_STORAGE_CLASS="${SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
TEST_NAMESPACE="${TEST_NAMESPACE:-cnv-snapshots-test}"
VM_NAME="${VM_NAME:-test-snapshot-vm}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-test-vm-snapshot}"
RESTORE_VM_NAME="${RESTORE_VM_NAME:-restored-vm}"
VM_CPU_REQUEST="${VM_CPU_REQUEST:-1}"
VM_MEMORY_REQUEST="${VM_MEMORY_REQUEST:-1Gi}"
VM_SNAPSHOT_TIMEOUT="${VM_SNAPSHOT_TIMEOUT:-10m}"

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

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

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
  if oc wait vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout="${VM_SNAPSHOT_TIMEOUT}"; then
    testStatus="passed"
  else
    testMessage="Snapshot not ready within ${VM_SNAPSHOT_TIMEOUT}"
    oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" -o yaml || true
    oc describe vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" || true
  fi
else
  testMessage="Failed to create VirtualMachineSnapshot resource"
fi

TestReport--AddCase "fa_cnv_1025_create_vm_snapshot" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  volumeSnapshots=$(oc get volumesnapshot -n "${TEST_NAMESPACE}" --no-headers 2>/dev/null | wc -l || echo "0")

  if [[ "${volumeSnapshots}" -gt 0 ]]; then
    oc get volumesnapshot -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,READYTOUSE:.status.readyToUse,SOURCEPVC:.spec.source.persistentVolumeClaimName"

    snapshotContent=$(oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.virtualMachineSnapshotContentName}' 2>/dev/null || echo "")
    if [[ -n "${snapshotContent}" ]]; then
      testStatus="passed"
    else
      testMessage="Snapshot content manifest not found"
    fi
  else
    testMessage="No VolumeSnapshot resources created"
  fi
else
  testMessage="VirtualMachineSnapshot resource not found"
fi

TestReport--AddCase "fa_cnv_1026_verify_vm_snapshot_exists" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

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
  if oc wait vmrestore "${RESTORE_VM_NAME}-restore" -n "${TEST_NAMESPACE}" --for=condition=Complete --timeout="${VM_SNAPSHOT_TIMEOUT}"; then
    if oc get vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
      if oc patch vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
        elapsed=0
        vmiFound=false

        while [[ "${elapsed}" -lt 120 ]]; do
          if oc get vmi "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
            vmiFound=true
            break
          fi
          sleep 5
          elapsed=$((elapsed + 5))
        done

        if [[ "${vmiFound}" == "true" ]]; then
          testStatus="passed"
        else
          testMessage="Restored VM VMI not created within timeout"
        fi
      else
        testMessage="Failed to start restored VM"
      fi
    else
      testMessage="Restored VM not found after restore operation"
    fi
  else
    testMessage="Restore not complete within ${VM_SNAPSHOT_TIMEOUT}"
    oc get vmrestore "${RESTORE_VM_NAME}-restore" -n "${TEST_NAMESPACE}" -o yaml || true
    oc describe vmrestore "${RESTORE_VM_NAME}-restore" -n "${TEST_NAMESPACE}" || true
  fi
else
  testMessage="Failed to create VirtualMachineRestore resource"
fi

TestReport--AddCase "fa_cnv_1027_restore_vm_from_snapshot" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc delete vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}"; then
  elapsed=0
  snapshotDeleted=false

  while [[ "${elapsed}" -lt 120 ]]; do
    if ! oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
      snapshotDeleted=true
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ "${snapshotDeleted}" == "true" ]]; then
    if oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
      testStatus="passed"
    else
      testMessage="Original VM not found after snapshot deletion"
    fi
  else
    testMessage="Snapshot not deleted within 2m timeout"
    oc get vmsnapshot "${SNAPSHOT_NAME}" -n "${TEST_NAMESPACE}" -o yaml || true
  fi
else
  testMessage="Failed to delete VirtualMachineSnapshot resource"
fi

TestReport--AddCase "fa_cnv_1028_delete_vm_snapshot" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

if oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}' || true
fi
if oc get vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  oc patch vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}' || true
fi
sleep 10

oc delete vmrestore "${RESTORE_VM_NAME}-restore" -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete vmsnapshot -n "${TEST_NAMESPACE}" --all --ignore-not-found
oc delete vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete vm "${RESTORE_VM_NAME}" -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete datavolume "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found

true

