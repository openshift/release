#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

eval "$(curl -fsSL \
    https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/\
libs/bash/ci-operator/interop/common/TestReport--JunitXml.sh
)"

LP_IO__TR__RESULTS_FILE="${ARTIFACT_DIR}/junit_cnv_shared_storage_tests.xml"
LP_IO__TR__SUITE_NAME="CNV Shared Storage Tests"
LP_IO__TR__START_TIME="${SECONDS}"
trap 'TestReport--GenerateJunitXml' EXIT

CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
SHARED_STORAGE_CLASS="${SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
TEST_NAMESPACE="${TEST_NAMESPACE:-cnv-shared-storage-test}"
VM_CPU_REQUEST="${VM_CPU_REQUEST:-1}"
VM_MEMORY_REQUEST="${VM_MEMORY_REQUEST:-1Gi}"

echo "📋 Configuration:"
echo "  CNV Namespace: ${CNV_NAMESPACE}"
echo "  Test Namespace: ${TEST_NAMESPACE}"
echo "  Shared Storage Class: ${SHARED_STORAGE_CLASS}"
echo "  VM CPU Request: ${VM_CPU_REQUEST}"
echo "  VM Memory Request: ${VM_MEMORY_REQUEST}"
echo ""

# Create test namespace
echo "📁 Creating test namespace..."
oc create namespace "${TEST_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
echo "  ✅ Test namespace created: ${TEST_NAMESPACE}"

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

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: test-shared-storage-dv
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
  if oc wait datavolume test-shared-storage-dv -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout=10m; then
    testStatus="passed"
  else
    testMessage="DataVolume not ready within 10m timeout"
    oc get datavolume test-shared-storage-dv -n "${TEST_NAMESPACE}" -o yaml
  fi
else
  testMessage="Failed to create DataVolume resource"
fi

TestReport--AddCase "test_datavolume_creation_with_shared_storage" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-shared-storage-vm
  namespace: ${TEST_NAMESPACE}
spec:
  running: false
  template:
    metadata:
      labels:
        kubevirt.io/vm: test-shared-storage-vm
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
          claimName: test-shared-storage-dv
EOF
then
  if oc patch vm test-shared-storage-vm -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
    sleep 30

    if oc get vmi test-shared-storage-vm -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp" 2>/dev/null; then
      testStatus="passed"
    else
      testMessage="VMI not found after starting VM"
    fi
  else
    testMessage="Failed to start VM"
  fi
else
  testMessage="Failed to create VM resource"
fi

TestReport--AddCase "test_vm_creation_with_shared_storage" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-simple-shared-pvc
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${SHARED_STORAGE_CLASS}
EOF
then
  if oc wait pvc test-simple-shared-pvc -n "${TEST_NAMESPACE}" --for=condition=Bound --timeout=5m; then
    if oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-shared-storage-pod
  namespace: ${TEST_NAMESPACE}
spec:
  containers:
  - name: test-container
    image: quay.io/centos/centos:stream8
    command: ["/bin/bash"]
    args: ["-c", "echo 'Testing shared storage at \$(date)' > /shared-storage/test-data.txt && echo 'Data written successfully' && cat /shared-storage/test-data.txt && sleep 3600"]
    volumeMounts:
    - name: shared-storage
      mountPath: /shared-storage
  volumes:
  - name: shared-storage
    persistentVolumeClaim:
      claimName: test-simple-shared-pvc
  restartPolicy: Never
EOF
    then
      if oc wait pod test-shared-storage-pod -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
        oc logs test-shared-storage-pod -n "${TEST_NAMESPACE}" --tail=10
        testStatus="passed"
      else
        testMessage="Pod not ready within 2m timeout"
        oc describe pod test-shared-storage-pod -n "${TEST_NAMESPACE}"
      fi
    else
      testMessage="Failed to create test pod"
    fi
  else
    testMessage="PVC not bound within 5m timeout"
    oc get pvc test-simple-shared-pvc -n "${TEST_NAMESPACE}" -o yaml
  fi
else
  testMessage="Failed to create PVC resource"
fi

TestReport--AddCase "test_simple_pvc_and_pod_with_shared_storage" "${testStatus}" "$((SECONDS - testStart))" "${testMessage}"

if oc get vm test-shared-storage-vm -n "${TEST_NAMESPACE}" >/dev/null; then
  oc patch vm test-shared-storage-vm -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'
fi

oc delete vm test-shared-storage-vm -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete datavolume test-shared-storage-dv -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete pod test-shared-storage-pod -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete pvc test-simple-shared-pvc -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found

true
