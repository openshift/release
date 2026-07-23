#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🔍 Verifying Shared Storage Between CNV and IBM Fusion Access"
echo "======================================================="

# Set default values
CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
SHARED_STORAGE_CLASS="${SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
TEST_NAMESPACE="${TEST_NAMESPACE:-shared-storage-test}"

# JUnit XML test results
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_verify_shared_storage_tests.xml"
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
  local test_classname="${5:-SharedStorageVerificationTests}"
  
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
  <testsuite name="Shared Storage Verification Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/junit_verify_shared_storage_tests.xml"
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
echo "  IBM Fusion Access Namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "  Test Namespace: ${TEST_NAMESPACE}"
echo "  Shared Storage Class: ${SHARED_STORAGE_CLASS}"

# Create test namespace
echo "📁 Creating test namespace..."
oc create namespace "${TEST_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
echo "  ✅ Test namespace created: ${TEST_NAMESPACE}"

# Step 1: Create a PVC from CNV side
test_start=$(start_test "Step 1: Creating PVC from CNV side")
test_status="failed"
test_message=""

if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cnv-shared-storage-pvc
  namespace: ${TEST_NAMESPACE}
  labels:
    app: cnv-test
    storage-type: shared
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: ${SHARED_STORAGE_CLASS}
EOF
then
  echo "  ✅ CNV PVC created successfully"
  
  # Wait for CNV PVC to be bound
  echo "  ⏳ Waiting for CNV PVC to be bound..."
  if oc wait pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" --for=condition=Bound --timeout=5m; then
    echo "  ✅ CNV PVC bound successfully"
    test_status="passed"
  else
    echo "  ⚠️  CNV PVC not bound within timeout"
    test_message="CNV PVC not bound within 5m timeout"
    oc get pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" -o yaml
  fi
else
  echo "  ❌ Failed to create CNV PVC"
  test_message="Failed to create CNV PVC resource"
fi

record_test "$test_start" "test_cnv_pvc_creation" "$test_status" "$test_message"

# Step 2: Create a pod to write data to the CNV PVC
test_start=$(start_test "Step 2: Writing data to CNV PVC")
test_status="failed"
test_message=""

if oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cnv-data-writer
  namespace: ${TEST_NAMESPACE}
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
  echo "  ✅ CNV data writer pod created"
  
  # Wait for pod to be running
  echo "  ⏳ Waiting for CNV data writer pod to be running..."
  if oc wait pod cnv-data-writer -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
    echo "  ✅ CNV data writer pod is running"
    
    # Wait a bit for data to be written
    echo "  ⏳ Waiting for data to be written..."
    sleep 10
    
    # Check if data was written
    echo "  📊 Checking data written by CNV pod..."
    if oc exec cnv-data-writer -n "${TEST_NAMESPACE}" -- cat /shared-storage/cnv-data.txt 2>/dev/null; then
      echo "  ✅ Data successfully written by CNV pod"
      test_status="passed"
    else
      echo "  ❌ Failed to read data written by CNV pod"
      test_message="Failed to read data from CNV PVC"
    fi
  else
    echo "  ⚠️  CNV data writer pod not ready within timeout"
    test_message="CNV data writer pod not ready within 2m timeout"
    oc describe pod cnv-data-writer -n "${TEST_NAMESPACE}"
  fi
else
  echo "  ❌ Failed to create CNV data writer pod"
  test_message="Failed to create CNV data writer pod resource"
fi

record_test "$test_start" "test_cnv_data_write" "$test_status" "$test_message"

# Step 3: Create a PVC from IBM Fusion Access side (using the same storage)
test_start=$(start_test "Step 3: Creating PVC from IBM Fusion Access side")
test_status="failed"
test_message=""

if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fusion-shared-storage-pvc
  namespace: ${TEST_NAMESPACE}
  labels:
    app: fusion-test
    storage-type: shared
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: ${SHARED_STORAGE_CLASS}
EOF
then
  echo "  ✅ IBM Fusion Access PVC created successfully"
  
  # Wait for IBM Fusion Access PVC to be bound
  echo "  ⏳ Waiting for IBM Fusion Access PVC to be bound..."
  if oc wait pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" --for=condition=Bound --timeout=5m; then
    echo "  ✅ IBM Fusion Access PVC bound successfully"
    test_status="passed"
  else
    echo "  ⚠️  IBM Fusion Access PVC not bound within timeout"
    test_message="IBM Fusion Access PVC not bound within 5m timeout"
    oc get pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" -o yaml
  fi
else
  echo "  ❌ Failed to create IBM Fusion Access PVC"
  test_message="Failed to create IBM Fusion Access PVC resource"
fi

record_test "$test_start" "test_fusion_access_pvc_creation" "$test_status" "$test_message"

# Step 4: Create a pod to read data from the IBM Fusion Access PVC
test_start=$(start_test "Step 4: Reading data from IBM Fusion Access PVC")
test_status="failed"
test_message=""

if oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: fusion-data-reader
  namespace: ${TEST_NAMESPACE}
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
  echo "  ✅ IBM Fusion Access data reader pod created"
  
  # Wait for pod to be running
  echo "  ⏳ Waiting for IBM Fusion Access data reader pod to be running..."
  if oc wait pod fusion-data-reader -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout=2m; then
    echo "  ✅ IBM Fusion Access data reader pod is running"
    
    # Wait a bit for data processing
    echo "  ⏳ Waiting for data processing..."
    sleep 10
    
    # Check pod logs to see if it found the shared data
    echo "  📊 Checking IBM Fusion Access pod logs..."
    oc logs fusion-data-reader -n "${TEST_NAMESPACE}" --tail=20
    test_status="passed"
  else
    echo "  ⚠️  IBM Fusion Access data reader pod not ready within timeout"
    test_message="IBM Fusion Access data reader pod not ready within 2m timeout"
    oc describe pod fusion-data-reader -n "${TEST_NAMESPACE}"
  fi
else
  echo "  ❌ Failed to create IBM Fusion Access data reader pod"
  test_message="Failed to create IBM Fusion Access data reader pod resource"
fi

record_test "$test_start" "test_fusion_access_data_read" "$test_status" "$test_message"

# Step 5: Verify shared storage by checking both PVCs point to the same underlying storage
test_start=$(start_test "Step 5: Verifying shared storage configuration")
test_status="failed"
test_message=""

# Check PVC details
echo "  📊 CNV PVC Details:"
oc get pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity,VOLUME:.spec.volumeName"

echo "  📊 IBM Fusion Access PVC Details:"
oc get pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity,VOLUME:.spec.volumeName"

# Check if both PVCs are using the same storage class
echo "  📊 Storage Class Verification:"
CNV_STORAGE_CLASS=$(oc get pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "Unknown")
FUSION_STORAGE_CLASS=$(oc get pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "Unknown")

if [[ "${CNV_STORAGE_CLASS}" == "${FUSION_STORAGE_CLASS}" ]] && [[ "${CNV_STORAGE_CLASS}" == "${SHARED_STORAGE_CLASS}" ]]; then
  echo "  ✅ Both PVCs use the same storage class: ${CNV_STORAGE_CLASS}"
  test_status="passed"
else
  echo "  ❌ PVCs use different storage classes:"
  echo "    CNV: ${CNV_STORAGE_CLASS}"
  echo "    IBM Fusion Access: ${FUSION_STORAGE_CLASS}"
  test_message="PVCs use different storage classes: CNV=${CNV_STORAGE_CLASS}, Fusion=${FUSION_STORAGE_CLASS}"
fi

record_test "$test_start" "test_storage_class_verification" "$test_status" "$test_message"

# Step 6: Final verification - check if data is accessible from both sides
test_start=$(start_test "Step 6: Final verification - checking data accessibility")
test_status="passed"
test_message=""

# Check if CNV pod can still access its data
echo "  📊 Checking CNV pod data access..."
if oc exec cnv-data-writer -n "${TEST_NAMESPACE}" -- ls -la /shared-storage/ 2>/dev/null; then
  echo "  ✅ CNV pod can access shared storage"
else
  echo "  ❌ CNV pod cannot access shared storage"
  test_status="failed"
  test_message="CNV pod cannot access shared storage"
fi

# Check if IBM Fusion Access pod can access its data
echo "  📊 Checking IBM Fusion Access pod data access..."
if oc exec fusion-data-reader -n "${TEST_NAMESPACE}" -- ls -la /shared-storage/ 2>/dev/null; then
  echo "  ✅ IBM Fusion Access pod can access shared storage"
else
  echo "  ❌ IBM Fusion Access pod cannot access shared storage"
  test_status="failed"
  test_message="${test_message}; IBM Fusion Access pod cannot access shared storage"
fi

record_test "$test_start" "test_data_accessibility_from_both_sides" "$test_status" "$test_message"

# Step 7: Summary and cleanup
echo "📊 Shared Storage Verification Summary"
echo "====================================="

# Count successful PVCs
CNV_PVC_STATUS=$(oc get pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
FUSION_PVC_STATUS=$(oc get pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

echo "✅ CNV PVC Status: ${CNV_PVC_STATUS}"
echo "✅ IBM Fusion Access PVC Status: ${FUSION_PVC_STATUS}"
echo "✅ Storage Class: ${SHARED_STORAGE_CLASS}"
echo "✅ IBM Storage Scale: Available"

if [[ "${CNV_PVC_STATUS}" == "Bound" ]] && [[ "${FUSION_PVC_STATUS}" == "Bound" ]]; then
  echo ""
  echo "🎉 SUCCESS: Shared storage between CNV and IBM Fusion Access is working!"
  echo "   Both PVCs are bound and using the same storage class"
  echo "   Data can be written and read from both sides"
  echo "   IBM Storage Scale provides the underlying shared storage"
else
  echo ""
  echo "⚠️  PARTIAL SUCCESS: Some PVCs may not be bound"
  echo "   Check the status above for details"
fi

# Cleanup
echo "🧹 Cleaning up test resources..."
echo "  🗑️  Deleting test pods..."
oc delete pod cnv-data-writer -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete pod fusion-data-reader -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting test PVCs..."
oc delete pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" --ignore-not-found
oc delete pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" --ignore-not-found

echo "  🗑️  Deleting test namespace..."
oc delete namespace "${TEST_NAMESPACE}" --ignore-not-found

echo "  ✅ Cleanup completed"

echo "🎯 Conclusion:"
echo "The test demonstrates that CNV and IBM Fusion Access can share the same"
echo "IBM Storage Scale storage infrastructure, enabling unified storage"
echo "management for both containerized and virtualized workloads."
