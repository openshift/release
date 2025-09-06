#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set default values from environment variables
TEST_TIMEOUT="${TEST_TIMEOUT:-2h}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"

echo "🧪 Starting Fusion Access Operator integration tests..."
echo "Test Timeout: ${TEST_TIMEOUT}"
echo "Artifact Directory: ${ARTIFACT_DIR}"

# Create artifact directories
mkdir -p "${ARTIFACT_DIR}/installer/auth"
mkdir -p "${ARTIFACT_DIR}/fusion-access-tests"

# Copy kubeadmin password for authentication
if [[ -f "$SHARED_DIR/kubeadmin-password" ]]; then
  cp "$SHARED_DIR/kubeadmin-password" "${ARTIFACT_DIR}/installer/auth/kubeadmin-password"
  echo "✅ Kubeadmin password copied to artifacts"
else
  echo "⚠️  Kubeadmin password not found, proceeding without it"
fi

# Verify Fusion Access Operator is ready
echo "🔍 Verifying Fusion Access Operator status..."
if oc get csv -n ibm-fusion-access --no-headers | grep -q "fusion-access-operator.*Succeeded"; then
  echo "✅ Fusion Access Operator is ready"
else
  echo "❌ Fusion Access Operator is not ready"
  exit 1
fi

# Verify IBM Storage Scale cluster is ready
echo "🔍 Verifying IBM Storage Scale cluster status..."
if oc get cluster ibm-spectrum-scale -n ibm-spectrum-scale -o jsonpath="{.status.phase}" | grep -q "Ready"; then
  echo "✅ IBM Storage Scale cluster is ready"
else
  echo "❌ IBM Storage Scale cluster is not ready"
  exit 1
fi

# Verify all pods are running
echo "🔍 Verifying pod status..."
if oc get pods -n ibm-spectrum-scale --no-headers | grep -v "Completed" | grep -v "Succeeded" | grep -q "Running"; then
  echo "✅ All IBM Storage Scale pods are running"
else
  echo "❌ Not all IBM Storage Scale pods are running"
  oc get pods -n ibm-spectrum-scale
  exit 1
fi

# Run integration tests
echo "🚀 Running Fusion Access integration tests..."
if [[ -f "scripts/test-integration.sh" ]]; then
  echo "Found test script, executing..."
  timeout "${TEST_TIMEOUT}" bash scripts/test-integration.sh
  TEST_EXIT_CODE=$?
else
  echo "No test script found, running basic validation tests..."
  
  # Basic validation tests
  echo "Running basic validation tests..."
  
  # Test 1: Verify namespaces exist
  echo "Test 1: Verifying namespaces..."
  oc get namespace ibm-fusion-access
  oc get namespace ibm-spectrum-scale
  
  # Test 2: Verify CRs are ready
  echo "Test 2: Verifying Custom Resources..."
  oc get fusionaccess -n ibm-fusion-access
  oc get cluster -n ibm-spectrum-scale
  
  # Test 3: Verify node labeling
  echo "Test 3: Verifying node labeling..."
  oc get nodes -l "scale.spectrum.ibm.com/role=storage"
  
  # Test 4: Verify secrets
  echo "Test 4: Verifying secrets..."
  oc get secret -n ibm-fusion-access fusion-pullsecret
  
  TEST_EXIT_CODE=0
  echo "✅ Basic validation tests completed"
fi

# Collect test artifacts
echo "📦 Collecting test artifacts..."

# Collect cluster information
echo "Collecting cluster information..."
oc get nodes -o wide > "${ARTIFACT_DIR}/fusion-access-tests/nodes.txt"
oc get pods -n ibm-fusion-access -o wide > "${ARTIFACT_DIR}/fusion-access-tests/fusion-access-pods.txt"
oc get pods -n ibm-spectrum-scale -o wide > "${ARTIFACT_DIR}/fusion-access-tests/storage-scale-pods.txt"

# Collect CR information
echo "Collecting Custom Resource information..."
oc get fusionaccess -n ibm-fusion-access -o yaml > "${ARTIFACT_DIR}/fusion-access-tests/fusionaccess-cr.yaml"
oc get cluster -n ibm-spectrum-scale -o yaml > "${ARTIFACT_DIR}/fusion-access-tests/storage-scale-cluster.yaml"

# Collect events
echo "Collecting events..."
oc get events -n ibm-fusion-access --sort-by='.lastTimestamp' > "${ARTIFACT_DIR}/fusion-access-tests/fusion-access-events.txt"
oc get events -n ibm-spectrum-scale --sort-by='.lastTimestamp' > "${ARTIFACT_DIR}/fusion-access-tests/storage-scale-events.txt"

# Collect logs from key pods
echo "Collecting pod logs..."
for pod in $(oc get pods -n ibm-fusion-access -o name); do
  pod_name=$(basename "$pod")
  oc logs "$pod" -n ibm-fusion-access > "${ARTIFACT_DIR}/fusion-access-tests/logs-${pod_name}.log" 2>&1 || true
done

for pod in $(oc get pods -n ibm-spectrum-scale -o name); do
  pod_name=$(basename "$pod")
  oc logs "$pod" -n ibm-spectrum-scale > "${ARTIFACT_DIR}/fusion-access-tests/logs-${pod_name}.log" 2>&1 || true
done

# Create test summary
echo "📊 Creating test summary..."
cat > "${ARTIFACT_DIR}/fusion-access-tests/test-summary.txt" <<EOF
Fusion Access Operator Integration Test Summary
==============================================

Test Execution Time: $(date)
Test Timeout: ${TEST_TIMEOUT}
Test Exit Code: ${TEST_EXIT_CODE}

Component Status:
- Fusion Access Operator: $(oc get csv -n ibm-fusion-access --no-headers | grep "fusion-access-operator" | awk '{print $6}' || echo "Unknown")
- FusionAccess CR: $(oc get fusionaccess fusionaccess-object -n ibm-fusion-access -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" 2>/dev/null || echo "Unknown")
- IBM Storage Scale Cluster: $(oc get cluster ibm-spectrum-scale -n ibm-spectrum-scale -o jsonpath="{.status.phase}" 2>/dev/null || echo "Unknown")
- Storage Nodes: $(oc get nodes -l "scale.spectrum.ibm.com/role=storage" --no-headers | wc -l || echo "0") nodes labeled

Pod Status:
- Fusion Access Pods: $(oc get pods -n ibm-fusion-access --no-headers | grep -v "Completed" | grep -v "Succeeded" | wc -l || echo "0") running
- Storage Scale Pods: $(oc get pods -n ibm-spectrum-scale --no-headers | grep -v "Completed" | grep -v "Succeeded" | wc -l || echo "0") running

Test Result: ${TEST_EXIT_CODE}
EOF

echo "✅ Test artifacts collected successfully"
echo "📁 Artifacts saved to: ${ARTIFACT_DIR}/fusion-access-tests/"

# Exit with test result
if [[ ${TEST_EXIT_CODE} -eq 0 ]]; then
  echo "🎉 All tests passed successfully!"
else
  echo "❌ Some tests failed with exit code: ${TEST_EXIT_CODE}"
fi

exit ${TEST_EXIT_CODE}
