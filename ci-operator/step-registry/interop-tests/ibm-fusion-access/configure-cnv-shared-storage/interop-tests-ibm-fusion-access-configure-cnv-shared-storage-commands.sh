#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🔧 Configuring CNV for IBM Storage Scale shared storage..."

# Set default values
CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
SHARED_STORAGE_CLASS="${SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

# JUnit XML test results
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_configure_cnv_shared_storage_tests.xml"
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
  local test_classname="${5:-CNVSharedStorageConfigurationTests}"
  
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
  <testsuite name="CNV Shared Storage Configuration Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/junit_configure_cnv_shared_storage_tests.xml"
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
echo "  Shared Storage Class: ${SHARED_STORAGE_CLASS}"
echo "  Storage Scale Namespace: ${STORAGE_SCALE_NAMESPACE}"
echo "  Storage Scale Cluster: ${STORAGE_SCALE_CLUSTER_NAME}"
echo ""

# Check if CNV is ready
test_start=$(start_test "Checking CNV status")
test_status="failed"
test_message=""

if oc get hyperconverged kubevirt-hyperconverged -n "${CNV_NAMESPACE}" >/dev/null; then
  CNV_STATUS=$(oc get hyperconverged kubevirt-hyperconverged -n "${CNV_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
  echo "  ✅ CNV HyperConverged found (Status: ${CNV_STATUS})"
  test_status="passed"
else
  echo "  ❌ CNV HyperConverged not found"
  echo "  Please ensure CNV is installed before running this step"
  test_message="CNV HyperConverged not found"
fi

record_test "$test_start" "test_cnv_availability" "$test_status" "$test_message"

# Check if IBM Storage Scale is ready
echo ""
test_start=$(start_test "Checking IBM Storage Scale status")
test_status="failed"
test_message=""

if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null; then
  SCALE_STATUS=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")
  echo "  ✅ IBM Storage Scale Cluster found (Status: ${SCALE_STATUS})"
  test_status="passed"
else
  echo "  ❌ IBM Storage Scale Cluster not found"
  echo "  Please ensure IBM Storage Scale is deployed before running this step"
  test_message="IBM Storage Scale Cluster not found"
fi

record_test "$test_start" "test_storage_scale_cluster_availability" "$test_status" "$test_message"

# Check if shared filesystem exists
echo ""
test_start=$(start_test "Checking IBM Storage Scale filesystem")
test_status="failed"
test_message=""

if oc get filesystem shared-filesystem -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null; then
  FS_STATUS=$(oc get filesystem shared-filesystem -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")
  echo "  ✅ Shared filesystem found (Status: ${FS_STATUS})"
  test_status="passed"
else
  echo "  ❌ Shared filesystem not found"
  echo "  Please ensure IBM Storage Scale filesystem is created before running this step"
  test_message="IBM Storage Scale filesystem not found"
fi

record_test "$test_start" "test_storage_scale_filesystem_availability" "$test_status" "$test_message"

# Create shared storage class for CNV
echo ""
test_start=$(start_test "Creating shared storage class for CNV")
test_status="failed"
test_message=""

if oc get storageclass "${SHARED_STORAGE_CLASS}" >/dev/null; then
  echo "  ✅ Storage class ${SHARED_STORAGE_CLASS} already exists"
  test_status="passed"
else
  echo "  📝 Creating storage class ${SHARED_STORAGE_CLASS}..."
  if oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SHARED_STORAGE_CLASS}
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: spectrumscale.csi.ibm.com
parameters:
  volBackendFs: "shared-filesystem"
  clusterId: "${STORAGE_SCALE_CLUSTER_NAME}"
  permissions: "755"
  uid: "0"
  gid: "0"
  fsType: "gpfs"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
  then
    echo "  ✅ Storage class created successfully"
    test_status="passed"
  else
    echo "  ❌ Failed to create storage class"
    test_message="Failed to create storage class"
  fi
fi

record_test "$test_start" "test_storage_class_creation" "$test_status" "$test_message"

# Configure CNV to use shared storage
echo ""
test_start=$(start_test "Configuring CNV to use shared storage")
test_status="failed"
test_message=""

CURRENT_STORAGE_CLASS=$(oc get hco kubevirt-hyperconverged -n "${CNV_NAMESPACE}" -o jsonpath='{.spec.storage.defaultStorageClass}' 2>/dev/null || echo "")
if [[ "${CURRENT_STORAGE_CLASS}" == "${SHARED_STORAGE_CLASS}" ]]; then
  echo "  ✅ CNV already configured for shared storage"
  test_status="passed"
else
  echo "  📝 Setting CNV default storage class to ${SHARED_STORAGE_CLASS}..."
  if oc patch hco kubevirt-hyperconverged -n "${CNV_NAMESPACE}" --type=merge -p '{
    "spec": {
      "storage": {
        "defaultStorageClass": "'${SHARED_STORAGE_CLASS}'"
      }
    }
  }' 2>/dev/null; then
    echo "  ✅ CNV configured for shared storage"
    test_status="passed"
  else
    echo "  ❌ Failed to configure CNV for shared storage"
    test_message="Failed to patch HyperConverged resource"
  fi
fi

record_test "$test_start" "test_cnv_storage_configuration" "$test_status" "$test_message"

# Test shared storage with a PVC
echo ""
test_start=$(start_test "Testing shared storage with PVC")
test_status="failed"
test_message=""

if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-shared-storage-pvc
  namespace: ${CNV_NAMESPACE}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${SHARED_STORAGE_CLASS}
EOF
then
  echo "  ✅ Test PVC created successfully"
  
  # Wait for PVC to be bound
  echo "  ⏳ Waiting for PVC to be bound..."
  if oc wait pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" --for=condition=Bound --timeout=5m; then
    echo "  ✅ PVC bound successfully to shared storage"
    
    # Check PVC status
    PVC_STATUS=$(oc get pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "  📊 PVC Status: ${PVC_STATUS}"
    
    test_status="passed"
    
    # Clean up test PVC
    echo "  🧹 Cleaning up test PVC..."
    oc delete pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" --ignore-not-found
    echo "  ✅ Test PVC cleaned up"
  else
    echo "  ⚠️  PVC not bound within timeout, checking status..."
    oc get pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" -o yaml
    test_message="PVC not bound within 5m timeout"
    echo "  🧹 Cleaning up test PVC..."
    oc delete pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" --ignore-not-found
  fi
else
  echo "  ❌ Failed to create test PVC"
  test_message="Failed to create test PVC"
fi

record_test "$test_start" "test_pvc_binding_with_shared_storage" "$test_status" "$test_message"

# Verify configuration
echo ""
echo "🔍 Verifying CNV configuration..."
echo "  📊 CNV HyperConverged status:"
oc get hco kubevirt-hyperconverged -n "${CNV_NAMESPACE}" -o custom-columns="NAME:.metadata.name,AVAILABLE:.status.conditions[?(@.type=='Available')].status,STORAGE:.spec.storage.defaultStorageClass"

echo "  📊 Storage class configuration:"
oc get storageclass "${SHARED_STORAGE_CLASS}" -o custom-columns="NAME:.metadata.name,PROVISIONER:.provisioner,VOLUMEBINDINGMODE:.volumeBindingMode"

echo ""
echo "✅ CNV shared storage configuration completed successfully!"
echo "   CNV is now configured to use IBM Storage Scale shared storage"
echo "   VMs and DataVolumes will use the shared storage infrastructure"
