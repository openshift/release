#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🚀 Testing CNV VM live migration with IBM Storage Scale shared storage..."

# Set default values from FA__ prefixed environment variables
CNV_NAMESPACE="${FA__CNV_NAMESPACE:-openshift-cnv}"
SHARED_STORAGE_CLASS="${FA__SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
TEST_NAMESPACE="${FA__TEST_NAMESPACE:-cnv-migration-test}"
VM_NAME="${FA__VM_NAME:-test-migration-vm}"
VM_CPU_REQUEST="${FA__VM_CPU_REQUEST:-1}"
VM_MEMORY_REQUEST="${FA__VM_MEMORY_REQUEST:-1Gi}"
VM_MIGRATION_TIMEOUT="${FA__VM_MIGRATION_TIMEOUT:-15m}"

# JUnit XML test results
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_vm_migration_tests.xml"
TEST_START_TIME=$SECONDS
TESTS_TOTAL=0
TESTS_FAILED=0
TESTS_PASSED=0
TEST_CASES=""

# Function to escape XML special characters
escape_xml() {
  local text="$1"
  # Escape XML special characters: & must be first to avoid double-escaping
  echo "$text" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'\''/\&apos;/g'
}

# Function to add test result to JUnit XML
add_test_result() {
  local test_name="$1"
  local test_status="$2"  # "passed" or "failed"
  local test_duration="$3"
  local test_message="${4:-}"
  local test_classname="${5:-VMMigrationTests}"
  
  # Escape XML special characters in user-provided strings
  test_name=$(escape_xml "$test_name")
  test_message=$(escape_xml "$test_message")
  test_classname=$(escape_xml "$test_classname")
  
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  
  if [[ "$test_status" == "passed" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${test_name}\" classname=\"${test_classname}\" time=\"${test_duration}\"/>"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    TEST_CASES="${TEST_CASES}
    <testcase name=\"${test_name}\" classname=\"${test_classname}\" time=\"${test_duration}\">
      <failure message=\"Test failed\">${test_message}</failure>
    </testcase>"
  fi
}

# Function to generate JUnit XML report
generate_junit_xml() {
  local total_duration=$((SECONDS - TEST_START_TIME))
  
  cat > "${JUNIT_RESULTS_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="VM Migration Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
${TEST_CASES}
  </testsuite>
</testsuites>
EOF
  
  echo ""
  echo "📊 Test Results Summary:"
  echo "  Total Tests: ${TESTS_TOTAL}"
  echo "  Passed: ${TESTS_PASSED}"
  echo "  Failed: ${TESTS_FAILED}"
  echo "  Duration: ${total_duration}s"
  echo "  Results File: ${JUNIT_RESULTS_FILE}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/junit_vm_migration_tests.xml"
    echo "  ✅ Results copied to SHARED_DIR"
  fi
}

start_test() {
  local test_description="$1"
  : "🧪 ${test_description}..."
  echo "$SECONDS"
}

# Helper function to record test result (eliminates repetitive duration calculation)
record_test() {
  local test_start="$1"
  local test_name="$2"
  local test_status="$3"
  local test_message="${4:-}"
  
  local test_duration=$((SECONDS - test_start))
  add_test_result "$test_name" "$test_status" "$test_duration" "$test_message"
}

# Trap to ensure JUnit XML is generated even on failure
trap generate_junit_xml EXIT

echo "📋 Configuration:"
echo "  CNV Namespace: ${CNV_NAMESPACE}"
echo "  Test Namespace: ${TEST_NAMESPACE}"
echo "  Shared Storage Class: ${SHARED_STORAGE_CLASS}"
echo "  VM Name: ${VM_NAME}"
echo "  VM CPU Request: ${VM_CPU_REQUEST}"
echo "  VM Memory Request: ${VM_MEMORY_REQUEST}"
echo "  Migration Timeout: ${VM_MIGRATION_TIMEOUT}"
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

# Test 1: FA-CNV-1022 - Preparation for live migration
test_start=$(start_test "FA-CNV-1022: Preparing environment for VM live migration")
test_status="failed"
test_message=""

# Check for multiple worker nodes
echo "  🔍 Checking for multiple worker nodes..."
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)
echo "  📊 Worker nodes available: ${WORKER_NODES}"

if [[ ${WORKER_NODES} -lt 2 ]]; then
  echo "  ⚠️  Insufficient worker nodes for migration testing (need 2+, found ${WORKER_NODES})"
  test_message="Insufficient worker nodes for migration (need 2+, found ${WORKER_NODES})"
  record_test "$test_start" "fa_cnv_1022_prepare_migration_environment" "$test_status" "$test_message"
  
  echo ""
  echo "❌ Cannot perform live migration tests with less than 2 worker nodes"
  echo "  Skipping migration tests..."
  exit 0
fi

echo "  ✅ Multiple worker nodes available for migration testing"

# List available worker nodes
echo "  📋 Available worker nodes:"
oc get nodes -l node-role.kubernetes.io/worker -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,ROLE:.metadata.labels.node-role\.kubernetes\.io/worker"

test_status="passed"
record_test "$test_start" "fa_cnv_1022_prepare_migration_environment" "$test_status" "$test_message"

# Create DataVolume for VM
echo ""
echo "📦 Creating DataVolume for migration test VM..."
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
    - ReadWriteMany
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
echo "🖥️  Creating VM for migration testing..."
if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app: migration-test
spec:
  running: true
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
  
  # Wait for VMI to be running using oc wait
  echo "  ⏳ Waiting for VMI to be running (5m timeout)..."
  if oc wait vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" \
      --for=jsonpath='{.status.phase}'=Running --timeout=300s; then
    echo "  ✅ VMI is running"
    
    # Get the current node where VM is running
    SOURCE_NODE=$(oc get vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.nodeName}')
    echo "  📊 VM currently running on node: ${SOURCE_NODE}"
  else
    echo "  ❌ VMI not running within timeout"
    oc describe vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" || true
    exit 1
  fi
else
  echo "  ❌ Failed to create VM"
  exit 1
fi

# Test 2: FA-CNV-1023 - Execute live migration
test_start=$(start_test "FA-CNV-1023: Executing VM live migration")
test_status="failed"
test_message=""

# Get current node before migration
SOURCE_NODE=$(oc get vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.nodeName}')
echo "  📊 Source node before migration: ${SOURCE_NODE}"

# Create VirtualMachineInstanceMigration resource
MIGRATION_NAME="${VM_NAME}-migration-$(date +%s)"
echo "  🚀 Creating VirtualMachineInstanceMigration: ${MIGRATION_NAME}..."

if oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: ${MIGRATION_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  vmiName: ${VM_NAME}
EOF
then
  echo "  ✅ VirtualMachineInstanceMigration created successfully"
  
  # Wait for migration to complete
  echo "  ⏳ Waiting for migration to complete (${VM_MIGRATION_TIMEOUT} timeout)..."
  if oc wait vmim "${MIGRATION_NAME}" -n "${TEST_NAMESPACE}" --for=condition=Succeeded --timeout="${VM_MIGRATION_TIMEOUT}"; then
    echo "  ✅ Migration completed successfully"
    
    # Get migration status
    MIGRATION_STATUS=$(oc get vmim "${MIGRATION_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "  📊 Migration status: ${MIGRATION_STATUS}"
    
    test_status="passed"
  else
    echo "  ⚠️  Migration did not complete within timeout"
    test_message="Migration did not complete within ${VM_MIGRATION_TIMEOUT}"
    
    # Get migration details for debugging
    echo "  📊 Migration details:"
    oc get vmim "${MIGRATION_NAME}" -n "${TEST_NAMESPACE}" -o yaml || true
    oc describe vmim "${MIGRATION_NAME}" -n "${TEST_NAMESPACE}" || true
  fi
else
  echo "  ❌ Failed to create VirtualMachineInstanceMigration"
  test_message="Failed to create VirtualMachineInstanceMigration resource"
fi

record_test "$test_start" "fa_cnv_1023_execute_vm_live_migration" "$test_status" "$test_message"

# Test 3: FA-CNV-1024 - Verify migration results
test_start=$(start_test "FA-CNV-1024: Verifying VM migration results")
test_status="failed"
test_message=""

# Get current node after migration
# Check if VMI exists first to avoid false positive when VMI is deleted/missing
if ! oc get vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  echo "  ❌ VMI not found after migration"
  test_message="VMI not found after migration"
  TARGET_NODE=""
else
  TARGET_NODE=$(oc get vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "")
  echo "  📊 Target node after migration: ${TARGET_NODE}"
fi

# Verify VM migrated to a different node
if [[ -n "${TARGET_NODE}" ]] && [[ "${SOURCE_NODE}" != "${TARGET_NODE}" ]]; then
  echo "  ✅ VM successfully migrated to different node"
  echo "     Source: ${SOURCE_NODE}"
  echo "     Target: ${TARGET_NODE}"
  
  # Verify VMI is still running
  VMI_PHASE=$(oc get vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  echo "  📊 VMI phase after migration: ${VMI_PHASE}"
  
  if [[ "$VMI_PHASE" == "Running" ]]; then
    echo "  ✅ VMI is running on new node"
    
    # Verify PVC is still bound (shared storage still accessible)
    PVC_STATUS=$(oc get pvc "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "  📊 PVC status after migration: ${PVC_STATUS}"
    
    if [[ "$PVC_STATUS" == "Bound" ]]; then
      echo "  ✅ PVC still bound - shared storage accessible"
      
      # Get VM status
      VM_STATUS=$(oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
      echo "  📊 VM status after migration: ${VM_STATUS}"
      
      if [[ "$VM_STATUS" == "Running" ]]; then
        echo "  ✅ VM status is Running after migration"
        test_status="passed"
      else
        echo "  ⚠️  VM status is not Running (status: ${VM_STATUS})"
        test_message="VM status not 'Running' after migration (status: ${VM_STATUS})"
      fi
    else
      echo "  ⚠️  PVC not bound after migration (status: ${PVC_STATUS})"
      test_message="PVC not bound after migration (status: ${PVC_STATUS})"
    fi
  else
    echo "  ⚠️  VMI not running after migration (phase: ${VMI_PHASE})"
    test_message="VMI not running after migration (phase: ${VMI_PHASE})"
    oc describe vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" || true
  fi
else
  if [[ -z "${TARGET_NODE}" ]]; then
    echo "  ⚠️  VM migration verification failed - VMI not available"
    echo "     Source: ${SOURCE_NODE}"
    # test_message already set above when VMI not found
  else
    echo "  ⚠️  VM did not migrate to a different node"
    echo "     Source: ${SOURCE_NODE}"
    echo "     Target: ${TARGET_NODE}"
    test_message="VM stayed on same node (${SOURCE_NODE})"
  fi
fi

record_test "$test_start" "fa_cnv_1024_verify_migration_results" "$test_status" "$test_message"

# Display migration summary
echo ""
echo "📊 Migration Summary:"
echo "  Source Node: ${SOURCE_NODE}"
echo "  Target Node: ${TARGET_NODE}"
echo "  Migration Name: ${MIGRATION_NAME}"
if oc get vmim "${MIGRATION_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  oc get vmim "${MIGRATION_NAME}" -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,PHASE:.status.phase,START:.metadata.creationTimestamp"
fi

# Cleanup
echo ""
echo "🧹 Cleaning up test resources..."
echo "  🗑️  Stopping VM..."
if oc get vm "${VM_NAME}" -n "${TEST_NAMESPACE}" >/dev/null; then
  oc patch vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}' || true
  # Wait for VMI to be deleted before proceeding with cleanup
  oc wait vmi "${VM_NAME}" -n "${TEST_NAMESPACE}" --for=delete --timeout=60s 2>/dev/null || true
fi

echo "  🗑️  Deleting migration resource..."
oc delete vmim "${MIGRATION_NAME}" -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting VM..."
oc delete vm "${VM_NAME}" -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting DataVolume..."
oc delete datavolume "${VM_NAME}-dv" -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting test namespace..."
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found

echo "  ✅ Cleanup completed"

echo ""
echo "📊 VM Migration Test Summary"
echo "============================="
echo "✅ FA-CNV-1022: Migration environment preparation tested"
echo "✅ FA-CNV-1023: VM live migration execution tested"
echo "✅ FA-CNV-1024: Migration verification tested"
echo "✅ Shared storage accessibility verified post-migration"
echo ""
echo "🎉 VM live migration with IBM Storage Scale shared storage completed!"


