#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Verify PVC binding and pod mount of shared Storage Scale storage in the CNV test namespace; emit JUnit.
# Inputs: FA__CNV__TEST_NAMESPACE, FA__CNV__SHARED_STORAGE_CLASS, ARTIFACT_DIR, MAP_TESTS.
# Non-obvious: Creates a test namespace and workload to confirm shared storage is usable.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_verify_shared_storage_tests.xml"
typeset -i testStartTime="${SECONDS}"
typeset -i testsTotal=0
typeset -i testsFailed=0
typeset testCases testStart testStatus testMessage

function EscapeXml () {
  typeset text="${1}"; (($#)) && shift
  printf '%s' "${text}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g'

  true
}

function AddTestResult () {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset -i testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-SharedStorageVerificationTests}"; (($#)) && shift

  typeset escapedName=''
  escapedName="$(EscapeXml "${testName}")"
  typeset escapedMessage=''
  escapedMessage="$(EscapeXml "${testMessage}")"
  typeset escapedClassName=''
  escapedClassName="$(EscapeXml "${testClassName}")"

  ((++testsTotal))

  if [[ "${testStatus}" == "passed" ]]; then
    testCases="${testCases}
    <testcase name=\"${escapedName}\" classname=\"${escapedClassName}\" time=\"${testDuration}\"/>"
  else
    ((++testsFailed))
    testCases="${testCases}
    <testcase name=\"${escapedName}\" classname=\"${escapedClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${escapedMessage}</failure>
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
  <testsuite name="Shared Storage Verification Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  if [[ -n "${SHARED_DIR}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_verify_shared_storage_tests.xml"
  fi

  true
}

function RecordTest () {
  typeset -i testStart="${1}"; (($#)) && shift
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
if ! oc wait "namespace/${FA__CNV__TEST_NAMESPACE}" --for=create --timeout=1m; then
  oc get namespace "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
  exit 1
fi

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
  name: shared-storage-pvc
  namespace: default
  labels:
    app: shared-storage-test
    storage-type: shared
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 2Gi
  storageClassName: default
YAML
then
  if oc wait pvc shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Bound --timeout=15m; then
    testStatus="passed"
  else
    testMessage="Shared PVC not bound within 15m timeout"
    oc get pvc shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe pvc shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  testMessage="Failed to create shared PVC resource"
fi

RecordTest "${testStart}" "test_shared_pvc_creation" "${testStatus}" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c --arg ns "${FA__CNV__TEST_NAMESPACE}" '.metadata.namespace=$ns' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: cnv-data-writer
  namespace: default
  labels:
    app: cnv-test
spec:
  containers:
  - name: data-writer
    image: quay.io/centos/centos:stream8
    command: ["/bin/bash"]
    args: ["-c", "echo 'Data written from CNV side at $(date)' > /shared-storage/cnv-data.txt && echo 'CNV data written successfully' && sleep 3600"]
    volumeMounts:
    - name: shared-storage
      mountPath: /shared-storage
  volumes:
  - name: shared-storage
    persistentVolumeClaim:
      claimName: shared-storage-pvc
  restartPolicy: Never
YAML
then
  if oc wait pod cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
    if oc exec cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}" -- cat /shared-storage/cnv-data.txt; then
      testStatus="passed"
    else
      testMessage="Failed to read data written by CNV pod"
    fi
  else
    testMessage="CNV data writer pod not ready within 2m timeout"
    oc get pod cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe pod cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  testMessage="Failed to create CNV data writer pod resource"
fi

RecordTest "${testStart}" "test_cnv_data_write" "${testStatus}" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c --arg ns "${FA__CNV__TEST_NAMESPACE}" '.metadata.namespace=$ns' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: fusion-data-reader
  namespace: default
  labels:
    app: fusion-test
spec:
  containers:
  - name: data-reader
    image: quay.io/centos/centos:stream8
    command: ["/bin/bash"]
    args: ["-c", "echo 'Writing data from IBM Fusion Access side at $(date)' > /shared-storage/fusion-data.txt && sleep 3600"]
    volumeMounts:
    - name: shared-storage
      mountPath: /shared-storage
  volumes:
  - name: shared-storage
    persistentVolumeClaim:
      claimName: shared-storage-pvc
  restartPolicy: Never
YAML
then
  if oc wait pod fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
    if oc exec fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}" -- cat /shared-storage/cnv-data.txt; then
      testStatus="passed"
    else
      testMessage="cnv-data.txt not visible from Fusion pod on shared PVC"
    fi
  else
    testMessage="IBM Fusion Access data reader pod not ready within 2m timeout"
    oc get pod fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}" -o yaml --ignore-not-found
    if ! oc describe pod fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}"; then
      true
    fi
  fi
else
  testMessage="Failed to create IBM Fusion Access data reader pod resource"
fi

RecordTest "${testStart}" "test_fusion_access_data_read" "${testStatus}" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc exec cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}" -- cat /shared-storage/fusion-data.txt; then
  testStatus="passed"
else
  testMessage="fusion-data.txt not visible from CNV pod on shared PVC"
fi

RecordTest "${testStart}" "test_bidirectional_data_access" "${testStatus}" "${testMessage}"

testStart="${SECONDS}"
testStatus="failed"
testMessage=""

typeset pvcStorageClass=''
pvcStorageClass="$(oc get pvc shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.spec.storageClassName}' --ignore-not-found)"

if [[ "${pvcStorageClass}" == "${FA__CNV__SHARED_STORAGE_CLASS}" ]]; then
  testStatus="passed"
else
  testMessage="PVC uses storage class '${pvcStorageClass}', expected '${FA__CNV__SHARED_STORAGE_CLASS}'"
fi

RecordTest "${testStart}" "test_storage_class_verification" "${testStatus}" "${testMessage}"

oc delete pod cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete pod fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete pvc shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

true
