#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Run DataVolume and PVC tests using the shared Storage Scale storage class for CNV integration; emit JUnit.
# Inputs: ARTIFACT_DIR, MAP_TESTS, FA__CNV__TEST_NAMESPACE, FA__CNV__SHARED_STORAGE_CLASS, FA__CNV__VM_* sizing env vars.
# Non-obvious: Multi-step test blocks with JUnit recording for each subtest.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_cnv_shared_storage_tests.xml"
typeset -i testStartTime="${SECONDS}"
typeset -i testsTotal=0
typeset -i testsFailed=0
typeset testCases=''
typeset -i testStart=0
typeset testStatus=''
typeset testMessage=''

function EscapeXml () {
  typeset text="${1}"; (($#)) && shift
  sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g' <<< "${text}"
  true
}

function AddTestResult () {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-CNVSharedStorageTests}"; (($#)) && shift
  
  testName=$(EscapeXml "${testName}")
  testMessage=$(EscapeXml "${testMessage}")
  testClassName=$(EscapeXml "${testClassName}")
  
  testsTotal=$((testsTotal + 1))
  
  if [[ "${testStatus}" == "passed" ]]; then
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

function GenerateJunitXml () {
  typeset -i totalDuration=0
  totalDuration=$((SECONDS - testStartTime))
  
  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="CNV Shared Storage Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  if [[ -n "${SHARED_DIR}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_cnv_shared_storage_tests.xml"
  fi

  true
}

function RecordTest () {
  typeset testStart="${1}"; (($#)) && shift
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  
  typeset -i testDuration=0
  testDuration=$((SECONDS - testStart))
  AddTestResult "${testName}" "${testStatus}" "${testDuration}" "${testMessage}"

  true
}

trap '{( GenerateJunitXml; true )}' EXIT

oc create namespace "${FA__CNV__TEST_NAMESPACE}" --dry-run=client -o yaml --save-config | oc apply -f -
if ! oc wait "Namespace/${FA__CNV__TEST_NAMESPACE}" --for=create --timeout=1m; then
  oc get namespace "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

if ! oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" -o name; then
  oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" -o yaml --ignore-not-found
  exit 1
fi

# Test 1: Create DataVolume with shared storage
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c --arg ns "${FA__CNV__TEST_NAMESPACE}" --arg sc "${FA__CNV__SHARED_STORAGE_CLASS}" \
    '.metadata.namespace=$ns | .spec.pvc.storageClassName=$sc' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: test-shared-storage-dv
  namespace: placeholder
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
    storageClassName: placeholder
YAML
then
  if oc wait datavolume test-shared-storage-dv -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=10m; then
    testStatus="passed"
  else
    testMessage="DataVolume not ready within 10m timeout"
    oc get datavolume test-shared-storage-dv -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  fi
else
  testMessage="Failed to create DataVolume resource"
fi

RecordTest "${testStart}" "test_datavolume_creation_with_shared_storage" "${testStatus}" "${testMessage}"

# Test 2: Create VM with shared storage
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c --arg ns "${FA__CNV__TEST_NAMESPACE}" --arg mem "${FA__CNV__VM_MEMORY_REQUEST}" --arg cpu "${FA__CNV__VM_CPU_REQUEST}" \
    '.metadata.namespace=$ns | .spec.template.spec.domain.resources.requests.memory=$mem | .spec.template.spec.domain.resources.requests.cpu=$cpu' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-shared-storage-vm
  namespace: placeholder
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
            memory: placeholder
            cpu: placeholder
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
YAML
then
  oc get vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.printableStatus,AGE:.metadata.creationTimestamp"

  if oc patch vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
    if oc wait --for=jsonpath='{.status.phase}'=Running \
        vmi/test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" --timeout=300s; then
      testStatus="passed"
    else
      testMessage="VMI not running after starting VM"
      oc get vmi test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    fi
  else
    testMessage="Failed to start VM"
    oc get vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  fi
else
  testMessage="Failed to create VM resource"
fi

RecordTest "${testStart}" "test_vm_creation_with_shared_storage" "${testStatus}" "${testMessage}"

# Test 3: Create a simple PVC and pod to test shared storage
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c --arg ns "${FA__CNV__TEST_NAMESPACE}" --arg sc "${FA__CNV__SHARED_STORAGE_CLASS}" \
    '.metadata.namespace=$ns | .spec.storageClassName=$sc' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-simple-shared-pvc
  namespace: placeholder
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: placeholder
YAML
then
  if oc wait pvc test-simple-shared-pvc -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Bound --timeout=15m; then
    if {
      oc create -f - --dry-run=client -o json --save-config |
      jq -c --arg ns "${FA__CNV__TEST_NAMESPACE}" '.metadata.namespace=$ns' |
      yq -p json -o yaml eval .
    } 0<<'YAML' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-shared-storage-pod
  namespace: placeholder
spec:
  containers:
  - name: test-container
    image: quay.io/centos/centos:stream8
    command: ["/bin/bash"]
    args: ["-c", "echo 'Testing shared storage at $(date)' > /shared-storage/test-data.txt && echo 'Data written successfully' && cat /shared-storage/test-data.txt && sleep 3600"]
    volumeMounts:
    - name: shared-storage
      mountPath: /shared-storage
  volumes:
  - name: shared-storage
    persistentVolumeClaim:
      claimName: test-simple-shared-pvc
  restartPolicy: Never
YAML
    then
      if oc wait pod test-shared-storage-pod -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
        testStatus="passed"
        if ! oc logs test-shared-storage-pod -n "${FA__CNV__TEST_NAMESPACE}" --tail=10; then
          true
        fi
      else
        testMessage="Pod not ready within 2m timeout"
        oc get pod test-shared-storage-pod -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
        if ! oc describe pod test-shared-storage-pod -n "${FA__CNV__TEST_NAMESPACE}"; then
          true
        fi
      fi
    else
      testMessage="Failed to create test pod"
    fi
  else
    testMessage="PVC not bound within 15m timeout"
    oc get pvc test-simple-shared-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  fi
else
  testMessage="Failed to create PVC resource"
fi

RecordTest "${testStart}" "test_simple_pvc_and_pod_with_shared_storage" "${testStatus}" "${testMessage}"

oc get pvc -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity"
oc get vm -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.printableStatus,AGE:.metadata.creationTimestamp"
oc get pods -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp"

if oc get vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" -o name; then
  if ! oc patch vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
    oc get vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  fi
fi
oc delete vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete datavolume test-shared-storage-dv -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete pod test-shared-storage-pod -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete pvc test-simple-shared-pvc -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

true
