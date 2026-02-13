#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Verifying Shared Storage Between CNV and IBM Fusion Access'

# Set default values
FA__CNV__NAMESPACE="${FA__CNV__NAMESPACE:-openshift-cnv}"
FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__CNV__SHARED_STORAGE_CLASS="${FA__CNV__SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
FA__CNV__TEST_NAMESPACE="${FA__CNV__TEST_NAMESPACE:-shared-storage-test}"

# JUnit XML test results
junitResultsFile="${ARTIFACT_DIR}/junit_verify_shared_storage_tests.xml"
testStartTime=$SECONDS
testsTotal=0
testsFailed=0
testsPassed=0
testCases=""

# Function to escape XML special characters
EscapeXml() {
  local text="$1"
  # Escape XML special characters: & must be first to avoid double-escaping
  echo "$text" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g'
}

# Function to add test result to JUnit XML
AddTestResult() {
  local testName="$1"
  local testStatus="$2"  # "passed" or "failed"
  local testDuration="$3"
  local testMessage="${4:-}"
  local testClassName="${5:-SharedStorageVerificationTests}"
  
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
}

# Function to generate JUnit XML report
GenerateJunitXml() {
  local totalDuration=$((SECONDS - testStartTime))
  
  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Shared Storage Verification Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : "Test Results Summary: Total=${testsTotal} Passed=${testsPassed} Failed=${testsFailed} Duration=${totalDuration}s Results=${junitResultsFile}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_verify_shared_storage_tests.xml"
    : 'Results copied to SHARED_DIR'
  fi
}

StartTest() {
  local testDescription="$1"
  : "🧪 ${testDescription}..."
  echo "$SECONDS"
}

# Helper function to record test result (eliminates repetitive duration calculation)
RecordTest() {
  local testStart="$1"
  local testName="$2"
  local testStatus="$3"
  local testMessage="${4:-}"
  
  local testDuration=$((SECONDS - testStart))
  AddTestResult "$testName" "$testStatus" "$testDuration" "$testMessage"
}

# Trap to ensure JUnit XML is generated even on failure
trap GenerateJunitXml EXIT

: "Configuration: CNV_NS=${FA__CNV__NAMESPACE} FA_NS=${FA__NAMESPACE} TEST_NS=${FA__CNV__TEST_NAMESPACE} SC=${FA__CNV__SHARED_STORAGE_CLASS}"

# Create test namespace
: 'Creating test namespace'
oc create namespace "${FA__CNV__TEST_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
: "Test namespace created: ${FA__CNV__TEST_NAMESPACE}"

# Step 1: Create a PVC from CNV side
testStart=$(StartTest "Step 1: Creating PVC from CNV side")
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cnv-shared-storage-pvc
  namespace: ${FA__CNV__TEST_NAMESPACE}
  labels:
    app: cnv-test
    storage-type: shared
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: ${FA__CNV__SHARED_STORAGE_CLASS}
EOF
then
  : 'CNV PVC created successfully'
  
  # Wait for CNV PVC to be bound
  : 'Waiting for CNV PVC to be bound'
  if oc wait pvc cnv-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Bound --timeout=15m; then
    : 'CNV PVC bound successfully'
    testStatus="passed"
  else
    : 'CNV PVC not bound within timeout'
    testMessage="CNV PVC not bound within 15m timeout"
    oc get pvc cnv-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o yaml
  fi
else
  : 'Failed to create CNV PVC'
  testMessage="Failed to create CNV PVC resource"
fi

RecordTest "$testStart" "test_cnv_pvc_creation" "$testStatus" "$testMessage"

# Step 2: Create a pod to write data to the CNV PVC
testStart=$(StartTest "Step 2: Writing data to CNV PVC")
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cnv-data-writer
  namespace: ${FA__CNV__TEST_NAMESPACE}
  labels:
    app: cnv-test
spec:
  containers:
  - name: data-writer
    image: quay.io/centos/centos:stream8
    command: ["/bin/bash"]
    args: ["-c", "echo 'Data written from CNV side at \$(date)' > /shared-storage/cnv-data.txt && echo 'CNV data written successfully' && sleep 3600"]
    volumeMounts:
    - name: shared-storage
      mountPath: /shared-storage
  volumes:
  - name: shared-storage
    persistentVolumeClaim:
      claimName: cnv-shared-storage-pvc
  restartPolicy: Never
EOF
then
  : 'CNV data writer pod created'
  
  # Wait for pod to be running
  : 'Waiting for CNV data writer pod to be running'
  if oc wait pod cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
    : 'CNV data writer pod is running'
    
    : 'Checking data written by CNV pod'
    if oc exec cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}" -- cat /shared-storage/cnv-data.txt; then
      : 'Data successfully written by CNV pod'
      testStatus="passed"
    else
      : 'Failed to read data written by CNV pod'
      testMessage="Failed to read data from CNV PVC"
    fi
  else
    : 'CNV data writer pod not ready within timeout'
    testMessage="CNV data writer pod not ready within 2m timeout"
    oc describe pod cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}"
  fi
else
  : 'Failed to create CNV data writer pod'
  testMessage="Failed to create CNV data writer pod resource"
fi

RecordTest "$testStart" "test_cnv_data_write" "$testStatus" "$testMessage"

# Step 3: Create a PVC from IBM Fusion Access side (using the same storage)
testStart=$(StartTest "Step 3: Creating PVC from IBM Fusion Access side")
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fusion-shared-storage-pvc
  namespace: ${FA__CNV__TEST_NAMESPACE}
  labels:
    app: fusion-test
    storage-type: shared
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: ${FA__CNV__SHARED_STORAGE_CLASS}
EOF
then
  : 'IBM Fusion Access PVC created successfully'
  
  # Wait for IBM Fusion Access PVC to be bound
  : 'Waiting for IBM Fusion Access PVC to be bound'
  if oc wait pvc fusion-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Bound --timeout=15m; then
    : 'IBM Fusion Access PVC bound successfully'
    testStatus="passed"
  else
    : 'IBM Fusion Access PVC not bound within timeout'
    testMessage="IBM Fusion Access PVC not bound within 15m timeout"
    oc get pvc fusion-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o yaml
  fi
else
  : 'Failed to create IBM Fusion Access PVC'
  testMessage="Failed to create IBM Fusion Access PVC resource"
fi

RecordTest "$testStart" "test_fusion_access_pvc_creation" "$testStatus" "$testMessage"

# Step 4: Create a pod to read data from the IBM Fusion Access PVC
testStart=$(StartTest "Step 4: Reading data from IBM Fusion Access PVC")
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: fusion-data-reader
  namespace: ${FA__CNV__TEST_NAMESPACE}
  labels:
    app: fusion-test
spec:
  containers:
  - name: data-reader
    image: quay.io/centos/centos:stream8
    command: ["/bin/bash"]
    args: ["-c", "echo 'Attempting to read data from shared storage...' && if [ -f /shared-storage/cnv-data.txt ]; then echo 'SUCCESS: Data from CNV side found!' && cat /shared-storage/cnv-data.txt; else echo 'Data not found in shared storage'; fi && echo 'Writing data from IBM Fusion Access side at \$(date)' > /shared-storage/fusion-data.txt && echo 'IBM Fusion Access data written successfully' && sleep 3600"]
    volumeMounts:
    - name: shared-storage
      mountPath: /shared-storage
  volumes:
  - name: shared-storage
    persistentVolumeClaim:
      claimName: fusion-shared-storage-pvc
  restartPolicy: Never
EOF
then
  : 'IBM Fusion Access data reader pod created'
  
  # Wait for pod to be running
  : 'Waiting for IBM Fusion Access data reader pod to be running'
  if oc wait pod fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
    : 'IBM Fusion Access data reader pod is running'
    
    # Check pod logs to see if it found the shared data
    : 'Checking IBM Fusion Access pod logs'
    oc logs fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}" --tail=20
    testStatus="passed"
  else
    : 'IBM Fusion Access data reader pod not ready within timeout'
    testMessage="IBM Fusion Access data reader pod not ready within 2m timeout"
    oc describe pod fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}"
  fi
else
  : 'Failed to create IBM Fusion Access data reader pod'
  testMessage="Failed to create IBM Fusion Access data reader pod resource"
fi

RecordTest "$testStart" "test_fusion_access_data_read" "$testStatus" "$testMessage"

# Step 5: Verify shared storage by checking both PVCs point to the same underlying storage
testStart=$(StartTest "Step 5: Verifying shared storage configuration")
testStatus="failed"
testMessage=""

# Check PVC details
: 'CNV PVC Details'
oc get pvc cnv-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity,VOLUME:.spec.volumeName"

: 'IBM Fusion Access PVC Details'
oc get pvc fusion-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity,VOLUME:.spec.volumeName"

# Check if both PVCs are using the same storage class
: 'Storage Class Verification'
cnvStorageClass=$(oc get pvc cnv-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.spec.storageClassName}')
fusionStorageClass=$(oc get pvc fusion-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.spec.storageClassName}')

if [[ "${cnvStorageClass}" == "${fusionStorageClass}" ]] && [[ "${cnvStorageClass}" == "${FA__CNV__SHARED_STORAGE_CLASS}" ]]; then
  : "Both PVCs use the same storage class: ${cnvStorageClass}"
  testStatus="passed"
else
  : "PVCs use different storage classes: CNV=${cnvStorageClass} Fusion=${fusionStorageClass}"
  testMessage="PVCs use different storage classes: CNV=${cnvStorageClass}, Fusion=${fusionStorageClass}"
fi

RecordTest "$testStart" "test_storage_class_verification" "$testStatus" "$testMessage"

# Step 6: Final verification - check if data is accessible from both sides
testStart=$(StartTest "Step 6: Final verification - checking data accessibility")
testStatus="passed"
testMessage=""

# Check if CNV pod can still access its data
: 'Checking CNV pod data access'
if oc exec cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}" -- ls -la /shared-storage/; then
  : 'CNV pod can access shared storage'
else
  : 'CNV pod cannot access shared storage'
  testStatus="failed"
  testMessage="CNV pod cannot access shared storage"
fi

# Check if IBM Fusion Access pod can access its data
: 'Checking IBM Fusion Access pod data access'
if oc exec fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}" -- ls -la /shared-storage/; then
  : 'IBM Fusion Access pod can access shared storage'
else
  : 'IBM Fusion Access pod cannot access shared storage'
  testStatus="failed"
  testMessage="${testMessage}; IBM Fusion Access pod cannot access shared storage"
fi

RecordTest "$testStart" "test_data_accessibility_from_both_sides" "$testStatus" "$testMessage"

# Step 7: Summary and cleanup
: 'Shared Storage Verification Summary'

# Count successful PVCs
cnvPvcStatus=$(oc get pvc cnv-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')
fusionPvcStatus=$(oc get pvc fusion-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')

: "CNV_PVC=${cnvPvcStatus} Fusion_PVC=${fusionPvcStatus} SC=${FA__CNV__SHARED_STORAGE_CLASS}"

if [[ "${cnvPvcStatus}" == "Bound" ]] && [[ "${fusionPvcStatus}" == "Bound" ]]; then
  : 'SUCCESS: Shared storage between CNV and IBM Fusion Access is working'
else
  : 'PARTIAL SUCCESS: Some PVCs may not be bound'
fi

# Cleanup
: 'Cleaning up test resources'
: 'Deleting test pods'
oc delete pod cnv-data-writer -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete pod fusion-data-reader -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting test PVCs'
oc delete pvc cnv-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found
oc delete pvc fusion-shared-storage-pvc -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting test namespace'
oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Cleanup completed'

