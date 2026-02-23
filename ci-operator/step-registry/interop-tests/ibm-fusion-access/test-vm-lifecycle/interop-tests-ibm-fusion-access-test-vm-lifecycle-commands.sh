#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Testing CNV VM lifecycle operations with IBM Storage Scale shared storage'

# Set default values
FA__CNV__NAMESPACE="${FA__CNV__NAMESPACE:-openshift-cnv}"
FA__CNV__SHARED_STORAGE_CLASS="${FA__CNV__SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
FA__CNV__TEST_NAMESPACE="${FA__CNV__TEST_NAMESPACE:-cnv-lifecycle-test}"
FA__CNV__VM_NAME="${FA__CNV__VM_NAME:-test-lifecycle-vm}"
FA__CNV__VM_CPU_REQUEST="${FA__CNV__VM_CPU_REQUEST:-1}"
FA__CNV__VM_MEMORY_REQUEST="${FA__CNV__VM_MEMORY_REQUEST:-1Gi}"

# JUnit XML test results
junitResultsFile="${ARTIFACT_DIR}/junit_vm_lifecycle_tests.xml"
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
  typeset testClassName="${1:-VMLifecycleTests}"; (($#)) && shift
  
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
  <testsuite name="VM Lifecycle Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : "Test Results Summary: Total=${testsTotal} Passed=${testsPassed} Failed=${testsFailed} Duration=${totalDuration}s Results=${junitResultsFile}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_vm_lifecycle_tests.xml"
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

: "Configuration: CNV_NS=${FA__CNV__NAMESPACE} TEST_NS=${FA__CNV__TEST_NAMESPACE} SC=${FA__CNV__SHARED_STORAGE_CLASS} VM=${FA__CNV__VM_NAME} CPU=${FA__CNV__VM_CPU_REQUEST} MEM=${FA__CNV__VM_MEMORY_REQUEST}"

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

# Create DataVolume for VM
: 'Creating DataVolume for VM'
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
: 'Creating VM with shared storage'
if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${FA__CNV__VM_NAME}
  namespace: ${FA__CNV__TEST_NAMESPACE}
  labels:
    app: lifecycle-test
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

# Test 1: Start VM
testStart=$(StartTest "FA-CNV-1011 Prerequisite: Starting VM")
testStatus="failed"
testMessage=""

: 'Starting VM by setting spec.running=true'
if oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
  : 'VM start command sent'
  
  # Wait for VMI to be running
  : 'Waiting for VMI to be running (5m timeout)'
  if oc wait --for=jsonpath='{.status.phase}'=Running \
      vmi/"${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --timeout=300s; then
    : 'VMI is running'
    
    # Get VM status
      vmStatus=$(oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}')
      : "VM Status: ${vmStatus}"
      
      testStatus="passed"
    else
      : 'VMI not running within timeout'
    testMessage="VMI not running within 5m timeout"
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      : 'VMI description not available'
    fi
  fi
else
  : 'Failed to start VM'
  testMessage="Failed to patch VM spec.running=true"
fi

RecordTest "$testStart" "fa_cnv_1011_prerequisite_start_vm" "$testStatus" "$testMessage"

# If VM didn't start, we can't continue with remaining tests
if [[ "$testStatus" != "passed" ]]; then
  : 'VM failed to start - cannot continue with lifecycle tests'
  exit 1
fi

# Test 2: FA-CNV-1011 - Stop VM
testStart=$(StartTest "FA-CNV-1011: Stopping VM with shared storage")
testStatus="failed"
testMessage=""

: 'Stopping VM by setting spec.running=false'
if oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
  : 'VM stop command sent'
  
  # Wait for VMI to be deleted
  : 'Waiting for VMI to be deleted (5m timeout)'
  VMI_DELETED=false
  if oc wait --for=delete \
      vmi/"${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --timeout=300s; then
    VMI_DELETED=true
  fi
  
  if [[ "$VMI_DELETED" == "true" ]]; then
    : 'VMI deleted successfully'
    
    # Verify VM status shows Stopped
    vmStatus=$(oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}')
    : "VM Status after stop: ${vmStatus}"
    
    if [[ "$vmStatus" == "Stopped" ]]; then
      : 'VM status is Stopped'
      testStatus="passed"
    else
      : "VM status is not Stopped (status: ${vmStatus})"
      testMessage="VM status not 'Stopped' after VMI deletion (status: ${vmStatus})"
    fi
  else
    : 'VMI not deleted within timeout'
    testMessage="VMI not deleted within 5m timeout"
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      : 'VMI description not available'
    fi
  fi
else
  : 'Failed to stop VM'
  testMessage="Failed to patch VM spec.running=false"
fi

RecordTest "$testStart" "fa_cnv_1011_stop_vm_with_shared_storage" "$testStatus" "$testMessage"

# Test 3: FA-CNV-1012 - Restart VM
testStart=$(StartTest "FA-CNV-1012: Restarting VM with shared storage")
testStatus="failed"
testMessage=""

: 'Restarting VM by setting spec.running=true'
if oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
  : 'VM restart command sent'
  
  # Wait for VMI to be running after restart
  : 'Waiting for VMI to be running (5m timeout)'
  if oc wait --for=jsonpath='{.status.phase}'=Running \
      vmi/"${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --timeout=300s; then
    : 'VMI is running after restart'
    
    # Get VM status
      vmStatus=$(oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}')
      : "VM Status after restart: ${vmStatus}"
      
      # Verify PVC is still bound (data persistence check)
      pvcStatus=$(oc get pvc "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')
      : "PVC Status: ${pvcStatus}"
      
      if [[ "$pvcStatus" == "Bound" ]]; then
        : 'PVC still bound - data persistence verified'
      testStatus="passed"
      else
        : "PVC not bound (status: ${pvcStatus})"
      testMessage="PVC not bound after VM restart (status: ${pvcStatus})"
    fi
  else
    : 'VMI not running within timeout after restart'
    testMessage="VMI not running within 5m timeout after restart"
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      : 'VMI description not available'
    fi
  fi
else
  : 'Failed to restart VM'
  testMessage="Failed to patch VM spec.running=true for restart"
fi

RecordTest "$testStart" "fa_cnv_1012_restart_vm_with_shared_storage" "$testStatus" "$testMessage"

# Cleanup
: 'Cleaning up test resources'
: 'Stopping VM'
if oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  if ! oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
    : 'VM may already be stopped'
  fi
fi
oc delete vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting VM'
oc delete vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting DataVolume'
oc delete datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting test namespace'
oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Cleanup completed'

: 'VM lifecycle operations with IBM Storage Scale shared storage completed'

true
