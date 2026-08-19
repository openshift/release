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

# Generate region cluster kubeconfig with embedded token
echo "Generating region cluster kubeconfig..."
set +x  # Hide sensitive token
REGION_CA=$(gcloud container clusters describe "${REGION_CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${REGION_PROJECT}" \
  --format='value(masterAuth.clusterCaCertificate)')

# Get DNS endpoint if available (falls back to public IP endpoint)
REGION_ENDPOINT=$(gcloud container clusters describe "${REGION_CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${REGION_PROJECT}" \
  --format='value(dnsConfig.clusterDns)')

# Fallback to private endpoint if DNS endpoint is not configured
# Use private endpoint for cluster-to-cluster connectivity from Prow pod
if [[ -z "${REGION_ENDPOINT}" ]]; then
  REGION_ENDPOINT=$(gcloud container clusters describe "${REGION_CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${REGION_PROJECT}" \
    --format='value(privateClusterConfig.privateEndpoint)')
fi

ACCESS_TOKEN=$(gcloud auth print-access-token)

cat > "${SHARED_DIR}/region-kubeconfig" << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${REGION_CA}
    server: https://${REGION_ENDPOINT}
  name: region-cluster
contexts:
- context:
    cluster: region-cluster
    user: gcp-user
  name: region-context
current-context: region-context
users:
- name: gcp-user
  user:
    token: ${ACCESS_TOKEN}
EOF

echo "  ✓ Region kubeconfig written"
set -x

# Generate MC cluster kubeconfig (optional - test skips if unavailable)
echo "Generating management cluster kubeconfig..."
set +x  # Hide sensitive token
if MC_CA=$(gcloud container clusters describe "${MC_CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${MC_PROJECT}" \
  --format='value(masterAuth.clusterCaCertificate)' 2>/dev/null); then
  
  # Get DNS endpoint if available (falls back to public IP endpoint)
  MC_ENDPOINT=$(gcloud container clusters describe "${MC_CLUSTER_NAME}" \
    --region="${REGION}" \
    --project="${MC_PROJECT}" \
    --format='value(dnsConfig.clusterDns)' 2>/dev/null)
  
  # Fallback to private endpoint if DNS endpoint is not configured
  # Use private endpoint for cluster-to-cluster connectivity from Prow pod
  if [[ -z "${MC_ENDPOINT}" ]]; then
    MC_ENDPOINT=$(gcloud container clusters describe "${MC_CLUSTER_NAME}" \
      --region="${REGION}" \
      --project="${MC_PROJECT}" \
      --format='value(privateClusterConfig.privateEndpoint)' 2>/dev/null)
  fi
  
  # Only create kubeconfig if we successfully got an endpoint
  if [[ -n "${MC_ENDPOINT}" ]]; then

  cat > "${SHARED_DIR}/mc-kubeconfig" << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${MC_CA}
    server: https://${MC_ENDPOINT}
  name: mc-cluster
contexts:
- context:
    cluster: mc-cluster
    user: gcp-user
  name: mc-context
current-context: mc-context
users:
- name: gcp-user
  user:
    token: ${ACCESS_TOKEN}
EOF

    echo "  ✓ MC kubeconfig written"
  else
    echo "  ⚠ MC endpoint unavailable - tests will skip MC validation"
  fi
else
  echo "  ⚠ MC cluster unavailable - tests will skip MC validation"
fi
set -x

echo ""
echo "✓ Kubeconfig generation completed"
