#!/usr/bin/env bash
set -euo pipefail

echo "=== GCP HCP Generate Kubeconfigs ==="
echo ""

# Authenticate with WIF credential
echo "Authenticating with WIF credential..."
if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "ERROR: WIF credential not found at ${SHARED_DIR}/wif-cred.json"
  exit 1
fi

gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet

# Read terraform outputs
REGION_PROJECT=$(<"${SHARED_DIR}/region-project-id")
REGION_CLUSTER_NAME=$(<"${SHARED_DIR}/region-cluster-name")
MC_PROJECT=$(<"${SHARED_DIR}/mc-project-id")
MC_CLUSTER_NAME=$(<"${SHARED_DIR}/mc-cluster-name")
REGION=${GCP_REGION:-us-central1}

echo "  Region Project:  ${REGION_PROJECT}"
echo "  Region Cluster:  ${REGION_CLUSTER_NAME}"
echo "  MC Project:      ${MC_PROJECT}"
echo "  MC Cluster:      ${MC_CLUSTER_NAME}"
echo "  Region:          ${REGION}"
echo ""

# Generate region cluster kubeconfig using gcloud
echo "Generating region cluster kubeconfig..."
export KUBECONFIG="${SHARED_DIR}/region-kubeconfig"
gcloud container clusters get-credentials "${REGION_CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${REGION_PROJECT}" \
  --dns-endpoint

echo "  ✓ Region kubeconfig written to ${SHARED_DIR}/region-kubeconfig"

# Generate MC cluster kubeconfig (optional - test skips if unavailable)
echo "Generating management cluster kubeconfig..."
if gcloud container clusters describe "${MC_CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${MC_PROJECT}" \
  --format='value(name)' &>/dev/null; then
  
  export KUBECONFIG="${SHARED_DIR}/mc-kubeconfig"
  gcloud container clusters get-credentials "${MC_CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${MC_PROJECT}" \
    --dns-endpoint
  
  echo "  ✓ MC kubeconfig written to ${SHARED_DIR}/mc-kubeconfig"
else
  echo "  ⚠ MC cluster unavailable - tests will skip MC validation"
fi

echo ""
echo "✓ Kubeconfig generation completed"
