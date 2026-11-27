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
REGION=${GCP_REGION:-northamerica-northeast2}

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

# Build Connect Gateway endpoint
# Format: https://{region}-connectgateway.googleapis.com/v1/projects/{projectNumber}/locations/{region}/gkeMemberships/{clusterName}
REGION_ENDPOINT="${REGION}-connectgateway.googleapis.com/v1/projects/${REGION_PROJECT_NUMBER}/locations/${REGION}/gkeMemberships/${REGION_CLUSTER_NAME}"

# Legacy regional checks and management checks use a one-hour token.
ACCESS_TOKEN=$(gcloud auth print-access-token)

# Connect Gateway uses Google's public TLS certificates (Google Trust Services),
# NOT the cluster's self-signed CA. No certificate-authority-data needed —
# the system CA bundle validates Google's certs automatically.
cat > "${SHARED_DIR}/region-kubeconfig" << 'KUBECONFIG_EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
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
KUBECONFIG_EOF

if [[ -e "${SHARED_DIR}/gcp-hcp-gar-expected" ]]; then
  # GAR revocation is checked late in the lifecycle test. Let client-go refresh
  # the access token from WIF ADC rather than embedding the initial token.
  cat >> "${SHARED_DIR}/region-kubeconfig" << 'KUBECONFIG_EOF'
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: gke-gcloud-auth-plugin
      args:
      - --use_application_default_credentials
      interactiveMode: Never
KUBECONFIG_EOF
else
  printf '    token: %s\n' "${ACCESS_TOKEN}" >> "${SHARED_DIR}/region-kubeconfig"
fi

sed -i "s|REGION_ENDPOINT_PLACEHOLDER|${REGION_ENDPOINT}|g" "${SHARED_DIR}/region-kubeconfig"

echo "  Region kubeconfig written (Connect Gateway)"
echo "  Endpoint: https://${REGION_ENDPOINT}"
set -x

# Generate MC cluster kubeconfig (optional - test skips if unavailable)
echo "Generating management cluster kubeconfig (Connect Gateway)..."
set +x  # Hide sensitive token
if gcloud projects describe "${MC_PROJECT}" --format='value(projectNumber)' &>/dev/null; then

  # MC clusters are registered in the REGION project's fleet (not their own).
  # Connect Gateway URLs must reference the project that owns the fleet membership.
  MC_ENDPOINT="${REGION}-connectgateway.googleapis.com/v1/projects/${REGION_PROJECT_NUMBER}/locations/${REGION}/gkeMemberships/${MC_CLUSTER_NAME}"

  cat > "${SHARED_DIR}/mc-kubeconfig" << 'KUBECONFIG_EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
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
  sed -i "s|MC_ENDPOINT_PLACEHOLDER|${MC_ENDPOINT}|g" "${SHARED_DIR}/mc-kubeconfig"
  sed -i "s|ACCESS_TOKEN_PLACEHOLDER|${ACCESS_TOKEN}|g" "${SHARED_DIR}/mc-kubeconfig"

  echo "  MC kubeconfig written (Connect Gateway)"
  echo "  Endpoint: https://${MC_ENDPOINT}"
else
  echo "  MC cluster unavailable - tests will skip MC validation"
fi
set -x

echo ""
echo "Kubeconfig generation completed (Connect Gateway)"
