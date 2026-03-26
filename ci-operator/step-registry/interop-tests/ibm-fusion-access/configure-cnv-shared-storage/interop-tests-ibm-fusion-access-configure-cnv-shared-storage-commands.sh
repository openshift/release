#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Validate CNV or KubeVirt prerequisites (HyperConverged) and Storage Scale cluster presence for shared storage tests; emit JUnit.
# Inputs: ARTIFACT_DIR, MAP_TESTS, FA__CNV__NAMESPACE, FA__SCALE__NAMESPACE, FA__SCALE__CLUSTER_NAME, SHARED_DIR.
# Non-obvious: ReportPortal mapping via yq when MAP_TESTS is true; JUnit encodes pass or fail for the configuration gate.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_configure_cnv_shared_storage_tests.xml"
typeset -i testStartTime="${SECONDS}"
typeset -i testsTotal=0
typeset -i testsFailed=0
typeset testCases=''

# Function to escape XML special characters
function EscapeXml () {
  typeset text="${1}"; (($#)) && shift
  printf '%s' "${text}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g'

  true
}

# Function to add test result to JUnit XML
function AddTestResult () {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-CNVSharedStorageConfigurationTests}"; (($#)) && shift

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

# Function to generate JUnit XML report
function GenerateJunitXml () {
  typeset -i totalDuration=$((SECONDS - testStartTime))

  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="CNV Shared Storage Configuration Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  if [[ -n "${SHARED_DIR}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_configure_cnv_shared_storage_tests.xml"
  fi

  true
}

# Helper function to record test result (eliminates repetitive duration calculation)
function RecordTest () {
  typeset testStart="${1}"; (($#)) && shift
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift

  typeset -i testDuration=$((SECONDS - testStart))
  AddTestResult "${testName}" "${testStatus}" "${testDuration}" "${testMessage}"

  true
}

trap '{( GenerateJunitXml; true )}' EXIT

# Check if CNV is ready
typeset testStart="${SECONDS}"
typeset testStatus="failed"
typeset testMessage=""

if oc get hyperconverged kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}"; then
  testStatus="passed"
else
  testMessage="CNV HyperConverged not found"
fi

RecordTest "${testStart}" "test_cnv_availability" "${testStatus}" "${testMessage}"

# Check if IBM Storage Scale is ready
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}"; then
  testStatus="passed"
else
  testMessage="IBM Storage Scale Cluster not found"
fi

RecordTest "${testStart}" "test_storage_scale_cluster_availability" "${testStatus}" "${testMessage}"

# Check if shared filesystem exists
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc get filesystem shared-filesystem -n "${FA__SCALE__NAMESPACE}"; then
  testStatus="passed"
else
  testMessage="IBM Storage Scale filesystem not found"
fi

RecordTest "${testStart}" "test_storage_scale_filesystem_availability" "${testStatus}" "${testMessage}"

# Create shared storage class for CNV
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}"; then
  testStatus="passed"
else
  typeset csiClusterId=''
  typeset getJson=''
  if getJson="$(oc get csiscaleoperator ibm-spectrum-scale-csi -n "${FA__SCALE__CSI_NAMESPACE}" -o json)"; then
    csiClusterId="$(printf '%s' "${getJson}" | jq -r 'first(.spec.clusters[]).id // empty')"
  fi
  if [[ -z "${csiClusterId}" ]]; then
    csiClusterId="${FA__SCALE__CLUSTER_NAME}"
  fi

  if {
    oc create -f - --dry-run=client -o json --save-config |
    jq -c --arg name "${FA__CNV__SHARED_STORAGE_CLASS}" --arg clusterId "${csiClusterId}" '.metadata.name = $name | .parameters.clusterId = $clusterId' |
    yq -p json -o yaml eval .
  } 0<<'YAML' | oc apply -f -; then
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: placeholder
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: spectrumscale.csi.ibm.com
parameters:
  volBackendFs: "shared-filesystem"
  clusterId: "placeholder"
  permissions: "755"
  uid: "0"
  gid: "0"
volumeBindingMode: Immediate
allowVolumeExpansion: true
reclaimPolicy: Delete
YAML
    testStatus="passed"
  else
    oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" -o yaml --ignore-not-found
    testMessage="Failed to create storage class"
  fi
fi

if [[ "${testStatus}" == "passed" ]]; then
  if ! oc annotate storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" \
    storageclass.kubevirt.io/is-default-virt-class="true" --overwrite; then
    oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" -o yaml --ignore-not-found
    testStatus="failed"
    testMessage="Failed to annotate storage class as default virt class"
  fi
fi

RecordTest "${testStart}" "test_storage_class_creation" "${testStatus}" "${testMessage}"

# Configure CNV to use shared storage
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

typeset currentStorageClass=''
if ! currentStorageClass="$(oc get hco kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}" -o jsonpath='{.spec.storage.defaultStorageClass}')"; then
  currentStorageClass=''
fi
if [[ "${currentStorageClass}" == "${FA__CNV__SHARED_STORAGE_CLASS}" ]]; then
  testStatus="passed"
else
  typeset patchJson=''
  patchJson=$(jq -cn --arg sc "${FA__CNV__SHARED_STORAGE_CLASS}" '{"spec": {"storage": {"defaultStorageClass": $sc}}}')
  if oc patch hco kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}" --type=merge -p "${patchJson}"; then
    testStatus="passed"
  else
    oc get hco kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}" -o yaml --ignore-not-found
    testMessage="Failed to patch HyperConverged resource"
  fi
fi

RecordTest "${testStart}" "test_cnv_storage_configuration" "${testStatus}" "${testMessage}"

# Wait for CSI driver to be operational before PVC test
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if oc wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=ibm-spectrum-scale-csi-operator \
    -n "${FA__SCALE__CSI_NAMESPACE}" --timeout=300s && \
   oc wait --for=condition=Ready pod \
    -l app=ibm-spectrum-scale-csi \
    -n "${FA__SCALE__CSI_NAMESPACE}" --timeout=300s; then
  testStatus="passed"
else
  testMessage="CSI driver not ready within 300s"
  oc get pods -n "${FA__SCALE__CSI_NAMESPACE}" -o yaml --ignore-not-found
fi

RecordTest "${testStart}" "test_csi_driver_readiness" "${testStatus}" "${testMessage}"

# Test shared storage with a PVC
testStart="${SECONDS}"
testStatus="failed"
testMessage=""

if {
  oc create -f - --dry-run=client -o json --save-config |
  jq -c --arg ns "${FA__CNV__NAMESPACE}" --arg sc "${FA__CNV__SHARED_STORAGE_CLASS}" '.metadata.namespace = $ns | .spec.storageClassName = $sc' |
  yq -p json -o yaml eval .
} 0<<'YAML' | oc apply -f -; then
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-shared-storage-pvc
  namespace: placeholder
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: placeholder
YAML
  if oc wait pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" --for=jsonpath='{.status.phase}'=Bound --timeout=15m; then
    testStatus="passed"
    oc delete pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" --ignore-not-found
  else
    oc get pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" -o yaml --ignore-not-found
    testMessage="PVC not bound within 15m timeout"
    oc delete pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" --ignore-not-found
  fi
else
  oc get pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" -o yaml --ignore-not-found
  testMessage="Failed to create test PVC"
fi

RecordTest "${testStart}" "test_pvc_binding_with_shared_storage" "${testStatus}" "${testMessage}"

oc get hco kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}" -o custom-columns="NAME:.metadata.name,AVAILABLE:.status.conditions[?(@.type=='Available')].status,STORAGE:.spec.storage.defaultStorageClass"
oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" -o custom-columns="NAME:.metadata.name,PROVISIONER:.provisioner,VOLUMEBINDINGMODE:.volumeBindingMode"

true
