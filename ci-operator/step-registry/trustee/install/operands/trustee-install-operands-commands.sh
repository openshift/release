#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set KUBECONFIG to target cluster
export KUBECONFIG=${SHARED_DIR}/kubeconfig

echo "Deploying Trustee operands via Helm template"

# Clone the coco-scenarios repository
TEMP_DIR=$(mktemp -d)
cd "${TEMP_DIR}"

echo "Cloning coco-scenarios repository..."
git clone https://github.com/beraldoleal/coco-scenarios.git
cd coco-scenarios/charts

# Debug: Check current context and namespace
echo "=== Debugging Info ==="
echo "Kubeconfig context:"
oc config view --minify
echo ""
echo "Available namespaces:"
oc get namespaces
echo "======================"

# Deploy trustee-operands using helm template
echo "Deploying trustee-operands..."
helm template trustee-operands trustee-operands \
  --namespace trustee-operator-system \
  --set profileType="${TRUSTEE_PROFILE_TYPE}" \
  --set crossCluster.enabled="${TRUSTEE_CROSS_CLUSTER}" \
  --set tests.enabled="${TRUSTEE_TESTS_ENABLED}" \
  > /tmp/operands.yaml

echo "Generated manifests:"
cat /tmp/operands.yaml

echo "Applying manifests with explicit namespace..."
oc apply -f /tmp/operands.yaml

# Wait for the trustee-deployment to be created and become ready
# The deployment is created by the KbsConfig controller, which may take a few seconds
echo "Waiting for Trustee deployment to be created..."
for i in {1..30}; do
  if oc get deployment trustee-deployment -n trustee-operator-system &>/dev/null; then
    echo "Deployment found, waiting for it to become available..."
    break
  fi
  if [ $i -eq 30 ]; then
    echo "Timeout waiting for deployment to be created"
    oc get deployment -n trustee-operator-system
    exit 1
  fi
  sleep 2
done

echo "Waiting for Trustee deployment to be ready..."
oc wait --for=condition=Available deployment/trustee-deployment \
  -n trustee-operator-system \
  --timeout=10m || {
  echo "Trustee deployment not ready, checking status..."
  echo "=== Trustee Deployment Status ==="
  oc get deployment -n trustee-operator-system
  oc describe deployment trustee-deployment -n trustee-operator-system || echo "Trustee deployment not found"
  echo "=== Trustee Operator Logs ==="
  oc logs -n trustee-operator-system deployment/trustee-operator-controller-manager --tail=50 || echo "Operator logs not available"
  echo "=== KbsConfig Status ==="
  oc get kbsconfig -n trustee-operator-system -o yaml
  echo "=== TrusteeConfig Status ==="
  oc get trusteeconfig -n trustee-operator-system -o yaml
  exit 1
}

# Cleanup
cd /
rm -rf "${TEMP_DIR}"

echo "Trustee operands deployed successfully"
