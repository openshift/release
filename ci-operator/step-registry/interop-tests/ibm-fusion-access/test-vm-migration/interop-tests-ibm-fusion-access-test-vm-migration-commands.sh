#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Testing CNV VM live migration with IBM Storage Scale shared storage'

# Set default values
FA__CNV__NAMESPACE="${FA__CNV__NAMESPACE:-openshift-cnv}"
FA__CNV__SHARED_STORAGE_CLASS="${FA__CNV__SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
FA__CNV__TEST_NAMESPACE="${FA__CNV__TEST_NAMESPACE:-cnv-migration-test}"
FA__CNV__VM_NAME="${FA__CNV__VM_NAME:-test-migration-vm}"
FA__CNV__VM_CPU_REQUEST="${FA__CNV__VM_CPU_REQUEST:-1}"
FA__CNV__VM_MEMORY_REQUEST="${FA__CNV__VM_MEMORY_REQUEST:-1Gi}"
FA__CNV__VM_MIGRATION_TIMEOUT="${FA__CNV__VM_MIGRATION_TIMEOUT:-30m}"

# JUnit XML test results
junitResultsFile="${ARTIFACT_DIR}/junit_vm_migration_tests.xml"
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
  typeset testClassName="${1:-VMMigrationTests}"; (($#)) && shift
  
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
  <testsuite name="VM Migration Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : "Test Results Summary: Total=${testsTotal} Passed=${testsPassed} Failed=${testsFailed} Duration=${totalDuration}s Results=${junitResultsFile}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/junit_vm_migration_tests.xml"
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

: "Configuration: CNV_NS=${FA__CNV__NAMESPACE} TEST_NS=${FA__CNV__TEST_NAMESPACE} SC=${FA__CNV__SHARED_STORAGE_CLASS} VM=${FA__CNV__VM_NAME} CPU=${FA__CNV__VM_CPU_REQUEST} MEM=${FA__CNV__VM_MEMORY_REQUEST} MIG_TIMEOUT=${FA__CNV__VM_MIGRATION_TIMEOUT}"

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

# Test 1: FA-CNV-1022 - Preparation for live migration
testStart=$(StartTest "FA-CNV-1022: Preparing environment for VM live migration")
testStatus="failed"
testMessage=""

# Check for multiple worker nodes
: 'Checking for multiple worker nodes'
workerNodes=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
: "Worker nodes available: ${workerNodes}"

if [[ ${workerNodes} -lt 2 ]]; then
  : "Insufficient worker nodes for migration testing (need 2+, found ${workerNodes})"
  testMessage="Insufficient worker nodes for migration (need 2+, found ${workerNodes})"
  RecordTest "$testStart" "fa_cnv_1022_prepare_migration_environment" "$testStatus" "$testMessage"
  
  : 'Cannot perform live migration tests with less than 2 worker nodes - skipping'
  exit 0
fi

: 'Multiple worker nodes available for migration testing'

# List available worker nodes
: 'Available worker nodes'
oc get nodes -l node-role.kubernetes.io/worker -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,ROLE:.metadata.labels.node-role\.kubernetes\.io/worker"

testStatus="passed"
RecordTest "$testStart" "fa_cnv_1022_prepare_migration_environment" "$testStatus" "$testMessage"

# Create DataVolume for VM
: 'Creating DataVolume for migration test VM'
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
    - ReadWriteMany
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
: 'Creating VM for migration testing'
if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${FA__CNV__VM_NAME}
  namespace: ${FA__CNV__TEST_NAMESPACE}
  labels:
    app: migration-test
spec:
  running: true
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
  
  # Wait for VMI to be running
  : 'Waiting for VMI to be running (5m timeout)'
  vmiRunning=false
  if oc wait --for=jsonpath='{.status.phase}'=Running \
      vmi/"${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --timeout=300s; then
    vmiRunning=true
  fi
  
  if [[ "$vmiRunning" == "true" ]]; then
    : 'VMI is running'
    
    # Get the current node where VM is running
    sourceNode=$(oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.nodeName}')
    : "VM currently running on node: ${sourceNode}"
  else
    : 'VMI not running within timeout'
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      : 'VMI description not available'
    fi
    exit 1
  fi
else
  : 'Failed to create VM'
  exit 1
fi

# Test 2: FA-CNV-1023 - Execute live migration
testStart=$(StartTest "FA-CNV-1023: Executing VM live migration")
testStatus="failed"
testMessage=""

# Get current node before migration
sourceNode=$(oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.nodeName}')
: "Source node before migration: ${sourceNode}"

# Create VirtualMachineInstanceMigration resource
migrationName="${FA__CNV__VM_NAME}-migration-$(date +%s)"
: "Creating VirtualMachineInstanceMigration: ${migrationName}"

if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: ${migrationName}
  namespace: ${FA__CNV__TEST_NAMESPACE}
spec:
  vmiName: ${FA__CNV__VM_NAME}
EOF
then
  : 'VirtualMachineInstanceMigration created successfully'
  
  # Wait for migration to complete
  : "Waiting for migration to complete (${FA__CNV__VM_MIGRATION_TIMEOUT} timeout)"
  if oc wait vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" --for=jsonpath='{.status.phase}'=Succeeded --timeout="${FA__CNV__VM_MIGRATION_TIMEOUT}"; then
    : 'Migration completed successfully'
    
    # Get migration status
    migrationStatus=$(oc get vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')
    : "Migration status: ${migrationStatus}"
    
    testStatus="passed"
  else
    : 'Migration did not complete within timeout'
    testMessage="Migration did not complete within ${FA__CNV__VM_MIGRATION_TIMEOUT}"
    
    # Get migration details for debugging
    : 'Migration details'
    if ! oc get vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" -o yaml; then
      : 'migration details not available'
    fi
    if ! oc describe vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      : 'migration description not available'
    fi
  fi
else
  : 'Failed to create VirtualMachineInstanceMigration'
  testMessage="Failed to create VirtualMachineInstanceMigration resource"
fi

RecordTest "$testStart" "fa_cnv_1023_execute_vm_live_migration" "$testStatus" "$testMessage"

# Test 3: FA-CNV-1024 - Verify migration results
testStart=$(StartTest "FA-CNV-1024: Verifying VM migration results")
testStatus="failed"
testMessage=""

# Get current node after migration
# Check if VMI exists first to avoid false positive when VMI is deleted/missing
if ! oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  : 'VMI not found after migration'
  testMessage="VMI not found after migration"
  targetNode=""
else
  targetNode=$(oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.nodeName}')
  : "Target node after migration: ${targetNode}"
fi

# Verify VM migrated to a different node
if [[ -n "${targetNode}" ]] && [[ "${sourceNode}" != "${targetNode}" ]]; then
  : "VM successfully migrated: Source=${sourceNode} Target=${targetNode}"
  
  # Verify VMI is still running
  vmiPhase=$(oc get vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')
  : "VMI phase after migration: ${vmiPhase}"
  
  if [[ "$vmiPhase" == "Running" ]]; then
    : 'VMI is running on new node'
    
    # Verify PVC is still bound (shared storage still accessible)
    pvcStatus=$(oc get pvc "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.phase}')
    : "PVC status after migration: ${pvcStatus}"
    
    if [[ "$pvcStatus" == "Bound" ]]; then
      : 'PVC still bound - shared storage accessible'
      
      # Get VM status
      vmStatus=$(oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}')
      : "VM status after migration: ${vmStatus}"
      
      if [[ "$vmStatus" == "Running" ]]; then
        : 'VM status is Running after migration'
        testStatus="passed"
      else
        : "VM status is not Running (status: ${vmStatus})"
        testMessage="VM status not 'Running' after migration (status: ${vmStatus})"
      fi
    else
      : "PVC not bound after migration (status: ${pvcStatus})"
      testMessage="PVC not bound after migration (status: ${pvcStatus})"
    fi
  else
    : "VMI not running after migration (phase: ${vmiPhase})"
    testMessage="VMI not running after migration (phase: ${vmiPhase})"
    if ! oc describe vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}"; then
      : 'VMI description not available'
    fi
  fi
else
  if [[ -z "${targetNode}" ]]; then
    : "VM migration verification failed - VMI not available, Source=${sourceNode}"
    # testMessage already set above when VMI not found
  else
    : "VM did not migrate to a different node: Source=${sourceNode} Target=${targetNode}"
    testMessage="VM stayed on same node (${sourceNode})"
  fi
fi

RecordTest "$testStart" "fa_cnv_1024_verify_migration_results" "$testStatus" "$testMessage"

# Display migration summary
: "Migration Summary: Source=${sourceNode} Target=${targetNode} Migration=${migrationName}"
if oc get vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  oc get vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,PHASE:.status.phase,START:.metadata.creationTimestamp"
fi

# Cleanup
: 'Cleaning up test resources'
: 'Stopping VM'
if oc get vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" >/dev/null; then
  if ! oc patch vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'; then
    : 'VM may already be stopped'
  fi
fi
oc delete vmi "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting migration resource'
oc delete vmim "${migrationName}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting VM'
oc delete vm "${FA__CNV__VM_NAME}" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting DataVolume'
oc delete datavolume "${FA__CNV__VM_NAME}-dv" -n "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Deleting test namespace'
oc delete namespace "${FA__CNV__TEST_NAMESPACE}" --ignore-not-found

: 'Cleanup completed'

: 'VM live migration with IBM Storage Scale shared storage completed'

true
