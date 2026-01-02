#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set KUBECONFIG to target cluster
export KUBECONFIG=${SHARED_DIR}/kubeconfig

echo "Installing Trustee operator via Helm template"

# Clone the coco-scenarios repository
TEMP_DIR=$(mktemp -d)
cd "${TEMP_DIR}"

echo "Cloning coco-scenarios repository..."
git clone https://github.com/beraldoleal/coco-scenarios.git
cd coco-scenarios/charts

# Install trustee-operator using helm template
echo "Installing trustee-operator..."
helm template trustee-operator trustee-operator \
  --namespace trustee-operator-system \
  --set dev.enabled="${TRUSTEE_DEV_MODE}" \
  --set dev.image="${TRUSTEE_DEV_IMAGE}" \
  | oc apply -f -

# Wait for the operator CSV to be installed
echo "Waiting for Trustee operator CSV to be ready..."
timeout 20m bash -c '
  until oc get csv -n trustee-operator-system -o name 2>/dev/null | grep -q trustee-operator; do
    echo "Waiting for CSV to appear..."
    sleep 10
  done
'

# Get the CSV name and wait for it to succeed
CSV_NAME=$(oc get csv -n trustee-operator-system -o name | grep trustee-operator)
echo "Found CSV: ${CSV_NAME}"
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  "${CSV_NAME}" \
  -n trustee-operator-system \
  --timeout=5m || {
  echo "CSV not ready, checking status..."
  oc get csv -n trustee-operator-system
  exit 1
}

# Wait for the operator deployment to be ready
echo "Waiting for Trustee operator deployment to be ready..."
oc wait --for=condition=available deployment/trustee-operator-controller-manager \
  -n trustee-operator-system \
  --timeout=2m || {
  echo "Trustee operator deployment not ready, checking status..."
  oc get pods -n trustee-operator-system
  exit 1
}

# Wait for CRDs to be established
echo "Waiting for Trustee CRDs to be established..."
oc wait --for=condition=established crd/trusteeconfigs.confidentialcontainers.org --timeout=2m || {
  echo "Trustee CRDs not established, listing available CRDs..."
  oc get crds | grep trustee
  exit 1
}
oc wait --for=condition=established crd/kbsconfigs.confidentialcontainers.org --timeout=2m || {
  echo "KBS CRDs not established, listing available CRDs..."
  oc get crds | grep kbs
  exit 1
}

# Cleanup
cd /
rm -rf "${TEMP_DIR}"

echo "Trustee operator installed successfully"
