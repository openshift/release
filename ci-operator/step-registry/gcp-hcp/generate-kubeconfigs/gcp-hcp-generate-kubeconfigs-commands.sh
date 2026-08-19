#!/usr/bin/env bash
set -euo pipefail

echo "=== GCP HCP Generate Kubeconfigs (Connect Gateway) ==="
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

# Generate region cluster kubeconfig with Connect Gateway endpoint
echo "Generating region cluster kubeconfig (Connect Gateway)..."
set +x  # Hide sensitive token

# Get project number for Connect Gateway URL
REGION_PROJECT_NUMBER=$(gcloud projects describe "${REGION_PROJECT}" --format='value(projectNumber)')

# Get cluster CA certificate
REGION_CA=$(gcloud container clusters describe "${REGION_CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${REGION_PROJECT}" \
  --format='value(masterAuth.clusterCaCertificate)')

# Build Connect Gateway endpoint
# Format: https://{region}-connectgateway.googleapis.com/v1/projects/{projectNumber}/locations/{region}/gkeMemberships/{clusterName}
REGION_ENDPOINT="${REGION}-connectgateway.googleapis.com/v1/projects/${REGION_PROJECT_NUMBER}/locations/${REGION}/gkeMemberships/${REGION_CLUSTER_NAME}"

# Get access token (valid for 1 hour - sufficient for CI jobs)
ACCESS_TOKEN=$(gcloud auth print-access-token)

cat > "${SHARED_DIR}/region-kubeconfig" << 'KUBECONFIG_EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: REGION_CA_PLACEHOLDER
    server: https://REGION_ENDPOINT_PLACEHOLDER
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
    token: ACCESS_TOKEN_PLACEHOLDER
KUBECONFIG_EOF

# Replace placeholders
sed -i "s|REGION_CA_PLACEHOLDER|${REGION_CA}|g" "${SHARED_DIR}/region-kubeconfig"
sed -i "s|REGION_ENDPOINT_PLACEHOLDER|${REGION_ENDPOINT}|g" "${SHARED_DIR}/region-kubeconfig"
sed -i "s|ACCESS_TOKEN_PLACEHOLDER|${ACCESS_TOKEN}|g" "${SHARED_DIR}/region-kubeconfig"

echo "  ✓ Region kubeconfig written (Connect Gateway)"
echo "  Endpoint: https://${REGION_ENDPOINT}"
set -x

# Generate MC cluster kubeconfig (optional - test skips if unavailable)
echo "Generating management cluster kubeconfig (Connect Gateway)..."
set +x  # Hide sensitive token
if MC_CA=$(gcloud container clusters describe "${MC_CLUSTER_NAME}" \
  --region="${REGION}" \
  --project="${MC_PROJECT}" \
  --format='value(masterAuth.clusterCaCertificate)' 2>/dev/null); then
  
  # Get MC project number
  MC_PROJECT_NUMBER=$(gcloud projects describe "${MC_PROJECT}" --format='value(projectNumber)')
  
  # Build Connect Gateway endpoint for MC
  MC_ENDPOINT="${REGION}-connectgateway.googleapis.com/v1/projects/${MC_PROJECT_NUMBER}/locations/${REGION}/gkeMemberships/${MC_CLUSTER_NAME}"
  
  cat > "${SHARED_DIR}/mc-kubeconfig" << 'KUBECONFIG_EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: MC_CA_PLACEHOLDER
    server: https://MC_ENDPOINT_PLACEHOLDER
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
    token: ACCESS_TOKEN_PLACEHOLDER
KUBECONFIG_EOF

  # Replace placeholders
  sed -i "s|MC_CA_PLACEHOLDER|${MC_CA}|g" "${SHARED_DIR}/mc-kubeconfig"
  sed -i "s|MC_ENDPOINT_PLACEHOLDER|${MC_ENDPOINT}|g" "${SHARED_DIR}/mc-kubeconfig"
  sed -i "s|ACCESS_TOKEN_PLACEHOLDER|${ACCESS_TOKEN}|g" "${SHARED_DIR}/mc-kubeconfig"

  echo "  ✓ MC kubeconfig written (Connect Gateway)"
  echo "  Endpoint: https://${MC_ENDPOINT}"
else
  echo "  ⚠ MC cluster unavailable - tests will skip MC validation"
fi
set -x

echo ""
echo "✓ Kubeconfig generation completed (Connect Gateway)"
