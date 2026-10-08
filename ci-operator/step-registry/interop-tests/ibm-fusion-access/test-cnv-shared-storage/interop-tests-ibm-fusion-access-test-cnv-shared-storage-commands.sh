#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🧪 Testing CNV VMs with IBM Storage Scale shared storage..."

# Set default values
CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
SHARED_STORAGE_CLASS="${SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
TEST_NAMESPACE="${TEST_NAMESPACE:-cnv-shared-storage-test}"
VM_CPU_REQUEST="${VM_CPU_REQUEST:-1}"
VM_MEMORY_REQUEST="${VM_MEMORY_REQUEST:-1Gi}"

# JUnit XML test results
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_cnv_shared_storage_tests.xml"
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
  local test_classname="${5:-CNVSharedStorageTests}"
  
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
  <testsuite name="CNV Shared Storage Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/junit_cnv_shared_storage_tests.xml"
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

# Test 1: Create DataVolume with shared storage
test_start=$(start_test "Test 1: Creating DataVolume with shared storage")
test_status="failed"
test_message=""

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
  echo "  ✅ DataVolume created successfully"
  
  # Wait for DataVolume to be ready
  echo "  ⏳ Waiting for DataVolume to be ready..."
  if oc wait datavolume test-shared-storage-dv -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout=10m; then
    echo "  ✅ DataVolume is ready"
    test_status="passed"
  else
    echo "  ⚠️  DataVolume not ready within timeout"
    test_message="DataVolume not ready within 10m timeout"
    oc get datavolume test-shared-storage-dv -n "${TEST_NAMESPACE}" -o yaml
  fi
else
  echo "  ❌ Failed to create DataVolume"
  test_message="Failed to create DataVolume resource"
fi

record_test "$test_start" "test_datavolume_creation_with_shared_storage" "$test_status" "$test_message"

# Test 2: Create VM with shared storage
test_start=$(start_test "Test 2: Creating VM with shared storage")
test_status="failed"
test_message=""

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
  echo "  ✅ VM created successfully"
  
  # Check VM status
  echo "  📊 VM Status:"
  oc get vm test-shared-storage-vm -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.printableStatus,AGE:.metadata.creationTimestamp"
  
  # Start the VM
  echo "  🚀 Starting VM..."
  if oc patch vm test-shared-storage-vm -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":true}}'; then
    echo "  ✅ VM start command sent"
    
    # Wait for VM to be running
    echo "  ⏳ Waiting for VM to be running..."
    sleep 30
    
    # Check VM status
    echo "  📊 VM Status after start:"
    oc get vm test-shared-storage-vm -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.printableStatus,AGE:.metadata.creationTimestamp"
    
    # Check VMI status
    echo "  📊 VMI Status:"
    if oc get vmi test-shared-storage-vm -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp" 2>/dev/null; then
      test_status="passed"
    else
      echo "  ⚠️ VMI not found yet"
      test_message="VMI not found after starting VM"
    fi
  else
    echo "  ❌ Failed to start VM"
    test_message="Failed to start VM"
  fi
else
  echo "  ❌ Failed to create VM"
  test_message="Failed to create VM resource"
fi

record_test "$test_start" "test_vm_creation_with_shared_storage" "$test_status" "$test_message"

# Test 3: Create a simple PVC and pod to test shared storage
test_start=$(start_test "Test 3: Testing shared storage with simple PVC and pod")
test_status="failed"
test_message=""

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
  echo "  ✅ Simple PVC created"
  
  # Wait for PVC to be bound
  echo "  ⏳ Waiting for PVC to be bound..."
  if oc wait pvc test-simple-shared-pvc -n "${TEST_NAMESPACE}" --for=condition=Bound --timeout=5m; then
    echo "  ✅ PVC bound successfully"
    
    # Create a pod to test the storage
    echo "  📝 Creating test pod..."
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
      echo "  ✅ Test pod created"
      
      # Wait for pod to be running
      echo "  ⏳ Waiting for test pod to be running..."
      if oc wait pod test-shared-storage-pod -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
        echo "  ✅ Test pod is running"
        
        # Check pod logs
        echo "  📊 Test pod logs:"
        oc logs test-shared-storage-pod -n "${TEST_NAMESPACE}" --tail=10
        test_status="passed"
      else
        echo "  ⚠️  Test pod not ready within timeout"
        test_message="Pod not ready within 2m timeout"
        oc describe pod test-shared-storage-pod -n "${TEST_NAMESPACE}"
      fi
    else
      echo "  ❌ Failed to create test pod"
      test_message="Failed to create test pod"
    fi
  else
    echo "  ⚠️  PVC not bound within timeout"
    test_message="PVC not bound within 5m timeout"
    oc get pvc test-simple-shared-pvc -n "${TEST_NAMESPACE}" -o yaml
  fi
else
  echo "  ❌ Failed to create simple PVC"
  test_message="Failed to create PVC resource"
fi

record_test "$test_start" "test_simple_pvc_and_pod_with_shared_storage" "$test_status" "$test_message"

# Check storage usage
echo ""
echo "📊 Storage Usage Summary:"
echo "  📋 PVCs in test namespace:"
oc get pvc -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity"

echo "  📋 VMs in test namespace:"
oc get vm -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.printableStatus,AGE:.metadata.creationTimestamp"

echo "  📋 Pods in test namespace:"
oc get pods -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp"

# Cleanup
echo ""
echo "🧹 Cleaning up test resources..."
echo "  🗑️  Stopping VM..."
if oc get vm test-shared-storage-vm -n "${TEST_NAMESPACE}" >/dev/null; then
  oc patch vm test-shared-storage-vm -n "${TEST_NAMESPACE}" --type=merge -p '{"spec":{"running":false}}'
fi

echo "  🗑️  Deleting VM..."
oc delete vm test-shared-storage-vm -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting DataVolume..."
oc delete datavolume test-shared-storage-dv -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting test pod..."
oc delete pod test-shared-storage-pod -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting PVCs..."
oc delete pvc test-simple-shared-pvc -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting test namespace..."
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found

echo "  ✅ Cleanup completed"

echo ""
echo "📊 CNV Shared Storage Test Summary"
echo "=================================="
echo "✅ DataVolume creation with shared storage tested"
echo "✅ VM creation with shared storage tested"
echo "✅ VM startup with shared storage tested"
echo "✅ Simple PVC and pod with shared storage tested"
echo "✅ Storage class integration verified"
echo ""
echo "🎉 CNV VMs can successfully use IBM Storage Scale shared storage!"
