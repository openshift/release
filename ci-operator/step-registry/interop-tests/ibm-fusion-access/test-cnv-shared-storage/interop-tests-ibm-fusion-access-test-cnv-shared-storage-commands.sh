#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Testing CNV VMs with IBM Storage Scale shared storage'

# Set default values
FA__CNV__NAMESPACE="${FA__CNV__NAMESPACE:-openshift-cnv}"
FA__CNV__SHARED_STORAGE_CLASS="${FA__CNV__SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
FA__CNV__TEST_NAMESPACE="${FA__CNV__TEST_NAMESPACE:-cnv-shared-storage-test}"
FA__CNV__VM_CPU_REQUEST="${FA__CNV__VM_CPU_REQUEST:-1}"
FA__CNV__VM_MEMORY_REQUEST="${FA__CNV__VM_MEMORY_REQUEST:-1Gi}"

# JUnit XML test results
junitResultsFile="${ARTIFACT_DIR}/junit_cnv_shared_storage_tests.xml"
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
  local testClassName="${5:-CNVSharedStorageTests}"
  
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
  <testsuite name="CNV Shared Storage Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : "Test Results Summary: Total=${testsTotal} Passed=${testsPassed} Failed=${testsFailed} Duration=${totalDuration}s Results=${junitResultsFile}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_cnv_shared_storage_tests.xml"
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

: "Configuration: CNV_NS=${FA__CNV__NAMESPACE} TEST_NS=${FA__CNV__TEST_NAMESPACE} SC=${FA__CNV__SHARED_STORAGE_CLASS} CPU=${FA__CNV__VM_CPU_REQUEST} MEM=${FA__CNV__VM_MEMORY_REQUEST}"

# Create test namespace
: 'Creating test namespace'
oc create namespace "${FA__CNV__TEST_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
: "Test namespace created: ${FA__CNV__TEST_NAMESPACE}"

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

# Test 1: Create DataVolume with shared storage
testStart=$(StartTest "Test 1: Creating DataVolume with shared storage")
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: test-shared-storage-dv
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
  : 'Waiting for DataVolume to be ready'
  if oc wait datavolume test-shared-storage-dv -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=10m; then
    : 'DataVolume is ready'
    testStatus="passed"
  else
    : 'DataVolume not ready within timeout'
    testMessage="DataVolume not ready within 10m timeout"
    oc get datavolume test-shared-storage-dv -n "${FA__CNV__TEST_NAMESPACE}" -o yaml
  fi
else
  : 'Failed to create DataVolume'
  testMessage="Failed to create DataVolume resource"
fi

RecordTest "$testStart" "test_datavolume_creation_with_shared_storage" "$testStatus" "$testMessage"

# Test 2: Create VM with shared storage
testStart=$(StartTest "Test 2: Creating VM with shared storage")
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-shared-storage-vm
  namespace: ${FA__CNV__TEST_NAMESPACE}
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
          claimName: test-shared-storage-dv
EOF
then
  : 'VM created successfully'
  
  # Check VM status
  : 'VM Status'
  oc get vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.printableStatus,AGE:.metadata.creationTimestamp"
  
  # Start the VM
  : 'Starting VM'
  if oc patch vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
    : 'VM start command sent'
    
    # Wait for VMI to be running
    : 'Waiting for VMI to be running'
    if oc wait --for=jsonpath='{.status.phase}'=Running \
        vmi/test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" --timeout=300s; then
      : 'VM Status after start'
      oc get vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.printableStatus,AGE:.metadata.creationTimestamp"
      
      : 'VMI Status'
      oc get vmi test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp"
      testStatus="passed"
    else
      : 'VMI not running within timeout'
      testMessage="VMI not running after starting VM"
    fi
  else
    : 'Failed to start VM'
    testMessage="Failed to start VM"
  fi
else
  : 'Failed to create VM'
  testMessage="Failed to create VM resource"
fi

RecordTest "$testStart" "test_vm_creation_with_shared_storage" "$testStatus" "$testMessage"

# Test 3: Create a simple PVC and pod to test shared storage
testStart=$(StartTest "Test 3: Testing shared storage with simple PVC and pod")
testStatus="failed"
testMessage=""

if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-simple-shared-pvc
  namespace: ${FA__CNV__TEST_NAMESPACE}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${FA__CNV__SHARED_STORAGE_CLASS}
EOF
then
  : 'Simple PVC created'
  
  # Wait for PVC to be bound
  : 'Waiting for PVC to be bound'
  if oc wait pvc test-simple-shared-pvc -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Bound --timeout=15m; then
    : 'PVC bound successfully'
    
    # Create a pod to test the storage
    : 'Creating test pod'
    if oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-shared-storage-pod
  namespace: ${FA__CNV__TEST_NAMESPACE}
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
      : 'Test pod created'
      
      # Wait for pod to be running
      : 'Waiting for test pod to be running'
      if oc wait pod test-shared-storage-pod -n "${FA__CNV__TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
        : 'Test pod is running'
        
        # Check pod logs
        : 'Test pod logs'
        oc logs test-shared-storage-pod -n "${FA__CNV__TEST_NAMESPACE}" --tail=10
        testStatus="passed"
      else
        : 'Test pod not ready within timeout'
        testMessage="Pod not ready within 2m timeout"
        oc describe pod test-shared-storage-pod -n "${FA__CNV__TEST_NAMESPACE}"
      fi
    else
      : 'Failed to create test pod'
      testMessage="Failed to create test pod"
    fi
  else
    : 'PVC not bound within timeout'
    testMessage="PVC not bound within 15m timeout"
    oc get pvc test-simple-shared-pvc -n "${FA__CNV__TEST_NAMESPACE}" -o yaml
  fi
else
  : 'Failed to create simple PVC'
  testMessage="Failed to create PVC resource"
fi

RecordTest "$testStart" "test_simple_pvc_and_pod_with_shared_storage" "$testStatus" "$testMessage"

# Check storage usage
: 'Storage Usage Summary'
: 'PVCs in test namespace'
oc get pvc -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity"

: 'VMs in test namespace'
oc get vm -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.printableStatus,AGE:.metadata.creationTimestamp"

: 'Pods in test namespace'
oc get pods -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp"

# Cleanup
: 'Cleaning up test resources'
: 'Stopping VM'
if oc get vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  oc patch vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'
fi

: 'Deleting VM'
oc delete vm test-shared-storage-vm -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting DataVolume'
oc delete datavolume test-shared-storage-dv -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting test pod'
oc delete pod test-shared-storage-pod -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting PVCs'
oc delete pvc test-simple-shared-pvc -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting test namespace'
oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Cleanup completed'

: 'CNV VMs can successfully use IBM Storage Scale shared storage'

