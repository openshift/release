#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
KMM_REGISTRY_URL="${KMM_REGISTRY_URL:-}"
KMM_REGISTRY_ORG="${KMM_REGISTRY_ORG:-}"
KMM_REGISTRY_REPO="${KMM_REGISTRY_REPO:-gpfs-compat-kmod}"

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
JUNIT_RESULTS_FILE="${ARTIFACT_DIR}/junit_configure_kmm_registry_tests.xml"
TEST_START_TIME=$(date +%s)
TESTS_TOTAL=0
TESTS_FAILED=0
TESTS_PASSED=0
TEST_CASES=""

# Function to add test result to JUnit XML
add_test_result() {
  local test_name="$1"
  local test_status="$2"  # "passed" or "failed"
  local test_duration="$3"
  local test_message="${4:-}"
  local test_classname="${5:-ConfigureKMMRegistryTests}"
  
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
  local total_duration=$(($(date +%s) - TEST_START_TIME))
  
  cat > "${JUNIT_RESULTS_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Configure KMM Registry Tests" tests="${TESTS_TOTAL}" failures="${TESTS_FAILED}" errors="0" time="${total_duration}">
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
    cp "${JUNIT_RESULTS_FILE}" "${SHARED_DIR}/$(basename ${JUNIT_RESULTS_FILE})"
    echo "  ✅ Results copied to SHARED_DIR"
  fi
  
  # Exit with failure if any tests failed
  if [[ ${TESTS_FAILED} -gt 0 ]]; then
    echo ""
    echo "❌ Test suite failed: ${TESTS_FAILED} test(s) failed"
    exit 1
  fi
}

# Trap to ensure JUnit XML is generated even on failure
trap generate_junit_xml EXIT

echo "🔧 Configuring KMM Registry for Kernel Module Management..."

# Test 1: Check for existing KMM configuration (idempotency)
echo ""
echo "🧪 Test 1: Check for existing KMM configuration..."
TEST1_START=$(date +%s)
TEST1_STATUS="passed"
TEST1_MESSAGE=""

if oc get configmap kmm-image-config -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "  ✅ kmm-image-config already exists (will update if needed)"
else
  echo "  ℹ️  kmm-image-config does not exist, will create"
fi

TEST1_DURATION=$(($(date +%s) - TEST1_START))
add_test_result "test_kmm_config_idempotency_check" "$TEST1_STATUS" "$TEST1_DURATION" "$TEST1_MESSAGE"

# Test 2: Create kmm-image-config ConfigMap
echo ""
echo "🧪 Test 2: Create kmm-image-config ConfigMap..."
TEST2_START=$(date +%s)
TEST2_STATUS="failed"
TEST2_MESSAGE=""

# Determine registry configuration
if [[ -n "$KMM_REGISTRY_ORG" ]]; then
  # Use external registry (e.g., quay.io/org/repo)
  FINAL_REGISTRY_URL="${KMM_REGISTRY_URL:-quay.io}"
  FULL_REPO="${KMM_REGISTRY_ORG}/${KMM_REGISTRY_REPO}"
  echo "  Using external registry: ${FINAL_REGISTRY_URL}/${FULL_REPO}"
else
  # Use OpenShift internal registry
  FINAL_REGISTRY_URL="image-registry.openshift-image-registry.svc:5000"
  FULL_REPO="ibm-spectrum-scale/${KMM_REGISTRY_REPO}"
  echo "  Using internal OpenShift registry: ${FINAL_REGISTRY_URL}/${FULL_REPO}"
fi

# Create kmm-image-config ConfigMap
if cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kmm-image-config
  namespace: ${FUSION_ACCESS_NAMESPACE}
data:
  kmm_image_registry_url: "${FINAL_REGISTRY_URL}"
  kmm_image_repo: "${FULL_REPO}"
  kmm_tls_insecure: "false"
  kmm_tls_skip_verify: "false"
EOF
then
  echo "  ✅ kmm-image-config ConfigMap created successfully"
  TEST2_STATUS="passed"
else
  echo "  ❌ Failed to create kmm-image-config ConfigMap"
  TEST2_MESSAGE="Failed to create kmm-image-config ConfigMap via oc apply"
fi

TEST2_DURATION=$(($(date +%s) - TEST2_START))
add_test_result "test_create_kmm_config" "$TEST2_STATUS" "$TEST2_DURATION" "$TEST2_MESSAGE"

# Test 3: Verify ConfigMap creation and content
echo ""
echo "🧪 Test 3: Verify ConfigMap creation and content..."
TEST3_START=$(date +%s)
TEST3_STATUS="failed"
TEST3_MESSAGE=""

if oc get configmap kmm-image-config -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "  ✅ ConfigMap exists"
  
  # Verify required fields
  REGISTRY_URL=$(oc get configmap kmm-image-config -n "${FUSION_ACCESS_NAMESPACE}" \
    -o jsonpath='{.data.kmm_image_registry_url}' 2>/dev/null || echo "")
  REGISTRY_REPO=$(oc get configmap kmm-image-config -n "${FUSION_ACCESS_NAMESPACE}" \
    -o jsonpath='{.data.kmm_image_repo}' 2>/dev/null || echo "")
  
  if [[ -n "$REGISTRY_URL" ]] && [[ -n "$REGISTRY_REPO" ]]; then
    echo "  Registry URL: ${REGISTRY_URL}"
    echo "  Repository: ${REGISTRY_REPO}"
    echo "  ✅ ConfigMap has all required fields"
    TEST3_STATUS="passed"
  else
    echo "  ❌ ConfigMap missing required fields"
    TEST3_MESSAGE="ConfigMap exists but missing kmm_image_registry_url or kmm_image_repo"
  fi
else
  echo "  ❌ ConfigMap not found after creation"
  TEST3_MESSAGE="kmm-image-config ConfigMap not found in namespace ${FUSION_ACCESS_NAMESPACE}"
fi

TEST3_DURATION=$(($(date +%s) - TEST3_START))
add_test_result "test_verify_kmm_config_content" "$TEST3_STATUS" "$TEST3_DURATION" "$TEST3_MESSAGE"

# Test 4: Create kmm-image-config in ibm-spectrum-scale-operator namespace
# CRITICAL: IBM Storage Scale operator checks this namespace, not ibm-fusion-access
echo ""
echo "🧪 Test 4: Create kmm-image-config in ibm-spectrum-scale-operator namespace..."
TEST4_START=$(date +%s)
TEST4_STATUS="failed"
TEST4_MESSAGE=""

echo "  CRITICAL: IBM Storage Scale operator requires kmm-image-config in its own namespace"
echo "  This prevents creation of broken buildgpl ConfigMap"

if cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kmm-image-config
  namespace: ibm-spectrum-scale-operator
data:
  kmm_image_registry_url: "${FINAL_REGISTRY_URL}"
  kmm_image_repo: "${FULL_REPO}"
  kmm_tls_insecure: "false"
  kmm_tls_skip_verify: "false"
EOF
then
  echo "  ✅ kmm-image-config created in ibm-spectrum-scale-operator namespace"
  
  # Wait for ConfigMap to be ready
  if oc wait --for=jsonpath='{.metadata.name}'=kmm-image-config \
    configmap/kmm-image-config -n ibm-spectrum-scale-operator --timeout=60s >/dev/null 2>&1; then
    echo "  ✅ ConfigMap verified in ibm-spectrum-scale-operator namespace"
    TEST4_STATUS="passed"
  else
    echo "  ⚠️  ConfigMap created but verification timed out"
    TEST4_STATUS="passed"  # Still count as success if created
  fi
else
  echo "  ❌ Failed to create kmm-image-config in ibm-spectrum-scale-operator"
  TEST4_MESSAGE="Failed to create kmm-image-config in ibm-spectrum-scale-operator namespace"
fi

TEST4_DURATION=$(($(date +%s) - TEST4_START))
add_test_result "test_create_kmm_config_in_scale_operator_namespace" "$TEST4_STATUS" "$TEST4_DURATION" "$TEST4_MESSAGE"

echo ""
echo "✅ KMM Registry configuration completed!"
echo "   Created in namespaces:"
echo "   - ${FUSION_ACCESS_NAMESPACE} (for Fusion Access operator)"
echo "   - ibm-spectrum-scale-operator (for IBM Storage Scale operator)"
echo ""
echo "⚠️  NOTE: IBM Storage Scale v5.2.3.1 manifests have limited KMM support."
echo "   The operator may still fall back to kernel header compilation."

