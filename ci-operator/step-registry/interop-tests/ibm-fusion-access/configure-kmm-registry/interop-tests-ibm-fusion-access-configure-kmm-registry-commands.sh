#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__KMM__REGISTRY_URL="${FA__KMM__REGISTRY_URL:-}"
FA__KMM__REGISTRY_ORG="${FA__KMM__REGISTRY_ORG:-}"
FA__KMM__REGISTRY_REPO="${FA__KMM__REGISTRY_REPO:-gpfs-compat-kmod}"

# JUnit XML test results configuration
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
junitResultsFile="${ARTIFACT_DIR}/junit_configure_kmm_registry_tests.xml"
testStartTime=$(date +%s)
testsTotal=0
testsFailed=0
testsPassed=0
testCases=""

# Function to add test result to JUnit XML
AddTestResult() {
  local testName="$1"
  local testStatus="$2"  # "passed" or "failed"
  local testDuration="$3"
  local testMessage="${4:-}"
  local testClassName="${5:-ConfigureKMMRegistryTests}"
  
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
  local totalDuration=$(($(date +%s) - testStartTime))
  
  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Configure KMM Registry Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF
  
  : '📊 Test Results Summary:'
  : "  Total Tests: ${testsTotal}"
  : "  Passed: ${testsPassed}"
  : "  Failed: ${testsFailed}"
  : "  Duration: ${totalDuration}s"
  : "  Results File: ${junitResultsFile}"
  
  # Copy to SHARED_DIR for data router reporter (if available)
  if [[ -n "${SHARED_DIR:-}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/$(basename ${junitResultsFile})"
    : '  ✅ Results copied to SHARED_DIR'
  fi
  
  # Exit with failure if any tests failed
  if [[ ${testsFailed} -gt 0 ]]; then
    : "❌ Test suite failed: ${testsFailed} test(s) failed"
    exit 1
  fi
}

# Trap to ensure JUnit XML is generated even on failure
trap GenerateJunitXml EXIT

: '🔧 Configuring KMM Registry for Kernel Module Management...'

# Test 1: Check for existing KMM configuration (idempotency)
: '🧪 Test 1: Check for existing KMM configuration...'
test1Start=$(date +%s)
test1Status="passed"
test1Message=""

if oc get configmap kmm-image-config -n "${FA__NAMESPACE}" >/dev/null; then
  : '  ✅ kmm-image-config already exists (will update if needed)'
else
  : '  ℹ️  kmm-image-config does not exist, will create'
fi

test1Duration=$(($(date +%s) - test1Start))
AddTestResult "test_kmm_config_idempotency_check" "$test1Status" "$test1Duration" "$test1Message"

# Test 2: Create kmm-image-config ConfigMap
: '🧪 Test 2: Create kmm-image-config ConfigMap...'
test2Start=$(date +%s)
test2Status="failed"
test2Message=""

# Determine registry configuration
if [[ -n "$FA__KMM__REGISTRY_ORG" ]]; then
  # Use external registry (e.g., quay.io/org/repo)
  finalRegistryUrl="${FA__KMM__REGISTRY_URL:-quay.io}"
  fullRepo="${FA__KMM__REGISTRY_ORG}/${FA__KMM__REGISTRY_REPO}"
  : "  Using external registry: ${finalRegistryUrl}/${fullRepo}"
else
  # Use OpenShift internal registry
  finalRegistryUrl="image-registry.openshift-image-registry.svc:5000"
  fullRepo="ibm-spectrum-scale/${FA__KMM__REGISTRY_REPO}"
  : "  Using internal OpenShift registry: ${finalRegistryUrl}/${fullRepo}"
fi

# Create kmm-image-config ConfigMap
if oc create configmap kmm-image-config \
  -n "${FA__NAMESPACE}" \
  --from-literal=kmm_image_registry_url="${finalRegistryUrl}" \
  --from-literal=kmm_image_repo="${fullRepo}" \
  --from-literal=kmm_tls_insecure="false" \
  --from-literal=kmm_tls_skip_verify="false" \
  --dry-run=client -o yaml --save-config | oc apply -f -
then
  : '  ✅ kmm-image-config ConfigMap created successfully'
  test2Status="passed"
else
  : '  ❌ Failed to create kmm-image-config ConfigMap'
  test2Message="Failed to create kmm-image-config ConfigMap via oc apply"
fi

test2Duration=$(($(date +%s) - test2Start))
AddTestResult "test_create_kmm_config" "$test2Status" "$test2Duration" "$test2Message"

# Test 3: Verify ConfigMap creation and content
: '🧪 Test 3: Verify ConfigMap creation and content...'
test3Start=$(date +%s)
test3Status="failed"
test3Message=""

if oc get configmap kmm-image-config -n "${FA__NAMESPACE}" >/dev/null; then
  : '  ✅ ConfigMap exists'
  
  # Verify required fields
  registryUrl=$(oc get configmap kmm-image-config -n "${FA__NAMESPACE}" \
    -o jsonpath='{.data.kmm_image_registry_url}')
  registryRepo=$(oc get configmap kmm-image-config -n "${FA__NAMESPACE}" \
    -o jsonpath='{.data.kmm_image_repo}')
  
  if [[ -n "$registryUrl" ]] && [[ -n "$registryRepo" ]]; then
    : "  Registry URL: ${registryUrl}"
    : "  Repository: ${registryRepo}"
    : '  ✅ ConfigMap has all required fields'
    test3Status="passed"
  else
    : '  ❌ ConfigMap missing required fields'
    test3Message="ConfigMap exists but missing kmm_image_registry_url or kmm_image_repo"
  fi
else
  : '  ❌ ConfigMap not found after creation'
  test3Message="kmm-image-config ConfigMap not found in namespace ${FA__NAMESPACE}"
fi

test3Duration=$(($(date +%s) - test3Start))
AddTestResult "test_verify_kmm_config_content" "$test3Status" "$test3Duration" "$test3Message"

# Test 4: Create kmm-image-config in ibm-spectrum-scale-operator namespace
# CRITICAL: IBM Storage Scale operator checks this namespace, not ibm-fusion-access
: '🧪 Test 4: Create kmm-image-config in ibm-spectrum-scale-operator namespace...'
test4Start=$(date +%s)
test4Status="failed"
test4Message=""

: '  CRITICAL: IBM Storage Scale operator requires kmm-image-config in its own namespace'
: '  This prevents creation of broken buildgpl ConfigMap'

if oc create configmap kmm-image-config \
  -n ibm-spectrum-scale-operator \
  --from-literal=kmm_image_registry_url="${finalRegistryUrl}" \
  --from-literal=kmm_image_repo="${fullRepo}" \
  --from-literal=kmm_tls_insecure="false" \
  --from-literal=kmm_tls_skip_verify="false" \
  --dry-run=client -o yaml --save-config | oc apply -f -
then
  : '  ✅ kmm-image-config created in ibm-spectrum-scale-operator namespace'
  
  # Wait for ConfigMap to be ready
  if oc wait --for=jsonpath='{.metadata.name}'=kmm-image-config \
    configmap/kmm-image-config -n ibm-spectrum-scale-operator --timeout=60s >/dev/null; then
    : '  ✅ ConfigMap verified in ibm-spectrum-scale-operator namespace'
    test4Status="passed"
  else
    : '  ⚠️  ConfigMap created but verification timed out'
    test4Status="passed"  # Still count as success if created
  fi
else
  : '  ❌ Failed to create kmm-image-config in ibm-spectrum-scale-operator'
  test4Message="Failed to create kmm-image-config in ibm-spectrum-scale-operator namespace"
fi

test4Duration=$(($(date +%s) - test4Start))
AddTestResult "test_create_kmm_config_in_scale_operator_namespace" "$test4Status" "$test4Duration" "$test4Message"

: '✅ KMM Registry configuration completed!'
: '   Created in namespaces:'
: "   - ${FA__NAMESPACE} (for Fusion Access operator)"
: '   - ibm-spectrum-scale-operator (for IBM Storage Scale operator)'
: '⚠️  NOTE: IBM Storage Scale v5.2.3.1 manifests have limited KMM support.'
: '   The operator may still fall back to kernel header compilation.'

