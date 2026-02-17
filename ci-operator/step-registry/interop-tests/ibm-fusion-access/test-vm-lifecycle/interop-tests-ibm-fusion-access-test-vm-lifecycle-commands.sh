#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

eval "$(curl -fsSL \
    https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/\
libs/bash/ci-operator/interop/common/TestReport--JunitXml.sh
)"

LP_IO__TR__RESULTS_FILE="${ARTIFACT_DIR}/junit_vm_lifecycle_tests.xml"
LP_IO__TR__SUITE_NAME="VM Lifecycle Tests"
LP_IO__TR__START_TIME="${SECONDS}"
trap 'TestReport--GenerateJunitXml' EXIT

CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
SHARED_STORAGE_CLASS="${SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
TEST_NAMESPACE="${TEST_NAMESPACE:-cnv-lifecycle-test}"
VM_NAME="${VM_NAME:-test-lifecycle-vm}"
VM_CPU_REQUEST="${VM_CPU_REQUEST:-1}"
VM_MEMORY_REQUEST="${VM_MEMORY_REQUEST:-1Gi}"

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

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
  elapsed=0
  vmiFound=false

  while [[ "${elapsed}" -lt 300 ]]; do
    if oc get vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
      vmiFound=true
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ "${vmiFound}" == "true" ]]; then
    if timeout 300 bash -c "until oc get vmi ${VM_NAME} -n ${TEST_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Running'; do sleep 5; done"; then
      testStatus="passed"
    else
      testMessage="VMI not running within 5m timeout"
      oc describe vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" || true
    fi
  else
    testMessage="VMI not created within 5m timeout"
    oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" -o yaml || true
  fi
else
  testMessage="Failed to patch VM spec.running=true"
fi

TestReport--AddCase "fa_cnv_1011_prerequisite_start_vm" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

if [[ "${testStatus}" != "passed" ]]; then
  echo ""
  echo "❌ VM failed to start - cannot continue with lifecycle tests"
  exit 1
fi

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
  elapsed=0
  vmiDeleted=false

  while [[ "${elapsed}" -lt 300 ]]; do
    if ! oc get vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
      vmiDeleted=true
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ "${vmiDeleted}" == "true" ]]; then
    vmStatus=$(oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")

    if [[ "${vmStatus}" == "Stopped" ]]; then
      testStatus="passed"
    else
      testMessage="VM status not 'Stopped' after VMI deletion (status: ${vmStatus})"
    fi
  else
    testMessage="VMI not deleted within 5m timeout"
    oc describe vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" || true
  fi
else
  testMessage="Failed to patch VM spec.running=false"
fi

TestReport--AddCase "fa_cnv_1011_stop_vm_with_shared_storage" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
  elapsed=0
  vmiFound=false

  while [[ "${elapsed}" -lt 300 ]]; do
    if oc get vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
      vmiFound=true
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  if [[ "${vmiFound}" == "true" ]]; then
    if timeout 300 bash -c "until oc get vmi ${VM_NAME} -n ${TEST_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null | grep -q 'Running'; do sleep 5; done"; then
      pvcStatus=$(oc get pvc "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

      if [[ "${pvcStatus}" == "Bound" ]]; then
        testStatus="passed"
      else
        testMessage="PVC not bound after VM restart (status: ${pvcStatus})"
      fi
    else
      testMessage="VMI not running within 5m timeout after restart"
      oc describe vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" || true
    fi
  else
    testMessage="VMI not created within 5m timeout after restart"
    oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" -o yaml || true
  fi
else
  testMessage="Failed to patch VM spec.running=true for restart"
fi

TestReport--AddCase "fa_cnv_1012_restart_vm_with_shared_storage" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

if oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}' || true
  sleep 10
fi

oc delete vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete datavolume "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found

true

