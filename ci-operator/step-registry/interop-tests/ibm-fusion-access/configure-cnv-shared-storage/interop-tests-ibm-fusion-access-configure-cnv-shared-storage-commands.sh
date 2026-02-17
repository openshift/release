#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Configuring CNV for IBM Storage Scale shared storage'

# Set default values
FA__CNV__NAMESPACE="${FA__CNV__NAMESPACE:-openshift-cnv}"
FA__CNV__SHARED_STORAGE_CLASS="${FA__CNV__SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
FA__SCALE__CLUSTER_NAME="${FA__SCALE__CLUSTER_NAME:-ibm-spectrum-scale}"

# JUnit XML test results
junitResultsFile="${ARTIFACT_DIR}/junit_configure_cnv_shared_storage_tests.xml"
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
  typeset testClassName="${1:-CNVSharedStorageConfigurationTests}"; (($#)) && shift
  
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
  <testsuite name="CNV Shared Storage Configuration Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : "Test Results Summary: Total=${testsTotal} Passed=${testsPassed} Failed=${testsFailed} Duration=${totalDuration}s Results=${junitResultsFile}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_configure_cnv_shared_storage_tests.xml"
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

: "Configuration: CNV_NS=${FA__CNV__NAMESPACE} SC=${FA__CNV__SHARED_STORAGE_CLASS} SCALE_NS=${FA__SCALE__NAMESPACE} SCALE_CLUSTER=${FA__SCALE__CLUSTER_NAME}"

# Check if CNV is ready
testStart=$(StartTest "Checking CNV status")
testStatus="failed"
testMessage=""

if oc get hyperconverged kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}" >/dev/null; then
  cnvStatus=$(oc get hyperconverged kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
  : "CNV HyperConverged found (Status: ${cnvStatus})"
  testStatus="passed"
else
  : 'CNV HyperConverged not found - ensure CNV is installed before running this step'
  testMessage="CNV HyperConverged not found"
fi

RecordTest "$testStart" "test_cnv_availability" "$testStatus" "$testMessage"

# Check if IBM Storage Scale is ready
testStart=$(StartTest "Checking IBM Storage Scale status")
testStatus="failed"
testMessage=""

if oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  scaleStatus=$(oc get cluster "${FA__SCALE__CLUSTER_NAME}" -n "${FA__SCALE__NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}')
  : "IBM Storage Scale Cluster found (Status: ${scaleStatus})"
  testStatus="passed"
else
  : 'IBM Storage Scale Cluster not found - ensure it is deployed before running this step'
  testMessage="IBM Storage Scale Cluster not found"
fi

RecordTest "$testStart" "test_storage_scale_cluster_availability" "$testStatus" "$testMessage"

# Check if shared filesystem exists
testStart=$(StartTest "Checking IBM Storage Scale filesystem")
testStatus="failed"
testMessage=""

if oc get filesystem shared-filesystem -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  fsStatus=$(oc get filesystem shared-filesystem -n "${FA__SCALE__NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}')
  : "Shared filesystem found (Status: ${fsStatus})"
  testStatus="passed"
else
  : 'Shared filesystem not found - ensure it is created before running this step'
  testMessage="IBM Storage Scale filesystem not found"
fi

RecordTest "$testStart" "test_storage_scale_filesystem_availability" "$testStatus" "$testMessage"

# Create shared storage class for CNV
testStart=$(StartTest "Creating shared storage class for CNV")
testStatus="failed"
testMessage=""

if oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" >/dev/null; then
  : "Storage class ${FA__CNV__SHARED_STORAGE_CLASS} already exists"
  testStatus="passed"
else
  csiClusterId=$(oc get csiscaleoperator ibm-spectrum-scale-csi -n ibm-spectrum-scale-csi \
    -o jsonpath='{.spec.clusters[0].id}')

  if [[ -z "${csiClusterId}" ]]; then
    : 'WARNING: Could not read CSI cluster ID from CSIScaleOperator, falling back to cluster name'
    csiClusterId="${FA__SCALE__CLUSTER_NAME}"
  fi

  if oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${FA__CNV__SHARED_STORAGE_CLASS}
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: spectrumscale.csi.ibm.com
parameters:
  volBackendFs: "shared-filesystem"
  clusterId: "${csiClusterId}"
  permissions: "755"
  uid: "0"
  gid: "0"
volumeBindingMode: Immediate
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
  then
    : "Storage class created with clusterId=${csiClusterId}"
    testStatus="passed"
  else
    : 'Failed to create storage class'
    testMessage="Failed to create storage class"
  fi
fi

if [[ "${testStatus}" == "passed" ]]; then
  oc annotate storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" \
    storageclass.kubevirt.io/is-default-virt-class="true" --overwrite
fi

RecordTest "$testStart" "test_storage_class_creation" "$testStatus" "$testMessage"

# Configure CNV to use shared storage
testStart=$(StartTest "Configuring CNV to use shared storage")
testStatus="failed"
testMessage=""

currentStorageClass=$(oc get hco kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}" -o jsonpath='{.spec.storage.defaultStorageClass}')
if [[ "${currentStorageClass}" == "${FA__CNV__SHARED_STORAGE_CLASS}" ]]; then
  : 'CNV already configured for shared storage'
  testStatus="passed"
else
  : "Setting CNV default storage class to ${FA__CNV__SHARED_STORAGE_CLASS}"
  if oc patch hco kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}" --type=merge -p '{
    "spec": {
      "storage": {
        "defaultStorageClass": "'${FA__CNV__SHARED_STORAGE_CLASS}'"
      }
    }
  }'; then
    : 'CNV configured for shared storage'
    testStatus="passed"
  else
    : 'Failed to configure CNV for shared storage'
    testMessage="Failed to patch HyperConverged resource"
  fi
fi

RecordTest "$testStart" "test_cnv_storage_configuration" "$testStatus" "$testMessage"

# Wait for CSI driver to be operational before PVC test
testStart=$(StartTest "Waiting for CSI driver readiness")
testStatus="failed"
testMessage=""

if oc wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=ibm-spectrum-scale-csi-operator \
    -n ibm-spectrum-scale-csi --timeout=300s && \
   oc wait --for=condition=Ready pod \
    -l app=ibm-spectrum-scale-csi \
    -n ibm-spectrum-scale-csi --timeout=300s; then
  : 'CSI operator and node pods are ready'
  testStatus="passed"
else
  testMessage="CSI driver not ready within 300s"
  oc get pods -n ibm-spectrum-scale-csi --ignore-not-found
fi

RecordTest "$testStart" "test_csi_driver_readiness" "$testStatus" "$testMessage"

# Test shared storage with a PVC
testStart=$(StartTest "Testing shared storage with PVC")
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-shared-storage-pvc
  namespace: ${FA__CNV__NAMESPACE}
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${FA__CNV__SHARED_STORAGE_CLASS}
EOF
then
  : 'Test PVC created successfully'
  
  # Wait for PVC to be bound
  : 'Waiting for PVC to be bound'
  if oc wait pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" --for=jsonpath='{.status.phase}'=Bound --timeout=15m; then
    : 'PVC bound successfully to shared storage'
    
    # Check PVC status
    pvcStatus=$(oc get pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" -o jsonpath='{.status.phase}')
    : "PVC Status: ${pvcStatus}"
    
    testStatus="passed"
    
    # Clean up test PVC
    : 'Cleaning up test PVC'
    oc delete pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" --ignore-not-found
    : 'Test PVC cleaned up'
  else
    : 'PVC not bound within timeout, checking status'
    oc get pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" -o yaml
    testMessage="PVC not bound within 15m timeout"
    : 'Cleaning up test PVC'
    oc delete pvc test-shared-storage-pvc -n "${FA__CNV__NAMESPACE}" --ignore-not-found
  fi
else
  : 'Failed to create test PVC'
  testMessage="Failed to create test PVC"
fi

RecordTest "$testStart" "test_pvc_binding_with_shared_storage" "$testStatus" "$testMessage"

# Verify configuration
: 'Verifying CNV configuration'
: 'CNV HyperConverged status'
oc get hco kubevirt-hyperconverged -n "${FA__CNV__NAMESPACE}" -o custom-columns="NAME:.metadata.name,AVAILABLE:.status.conditions[?(@.type=='Available')].status,STORAGE:.spec.storage.defaultStorageClass"

: 'Storage class configuration'
oc get storageclass "${FA__CNV__SHARED_STORAGE_CLASS}" -o custom-columns="NAME:.metadata.name,PROVISIONER:.provisioner,VOLUMEBINDINGMODE:.volumeBindingMode"

: 'CNV shared storage configuration completed successfully'

true
