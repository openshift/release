#!/usr/bin/env bash

set -euo pipefail

# This step creates GCP infrastructure for hosted clusters using the hypershift CLI.
# It creates:
# 1. RSA keypair for service account token signing
# 2. WIF infrastructure (Workload Identity Pool, Provider, Service Accounts)
# 3. Network infrastructure (VPC, Subnet) in the customer project

echo "Starting GCP hosted cluster infrastructure setup..."

# Install Google Cloud CLI (hypershift-operator image doesn't have gcloud)
echo "Installing Google Cloud CLI..."
GCLOUD_SDK_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz"
GCLOUD_INSTALL_DIR="${HOME}/google-cloud-sdk"
curl -sL "${GCLOUD_SDK_URL}" | tar -xzf - -C "${HOME}"
export PATH="${GCLOUD_INSTALL_DIR}/bin:${PATH}"

# Authenticate gcloud and set ADC for hypershift CLI
gcloud auth activate-service-account --key-file="${CLUSTER_PROFILE_DIR}/credentials.json"
export GOOGLE_APPLICATION_CREDENTIALS="${CLUSTER_PROFILE_DIR}/credentials.json"

# Load configuration from provision step
HC_PROJECT_ID="$(<"${SHARED_DIR}/hosted-cluster-project-id")"
GCP_REGION="$(<"${SHARED_DIR}/gcp-region")"

# Generate cluster name from job ID (same pattern as Azure/other platforms)
# This will be used as infra-id for GCP resources.
# Constraints for GCP service account IDs:
# - Must start with a letter (prefix with 'ci')
# - Max 30 chars total, longest suffix is "-cloud-controller" (17 chars)
# - So infra-id max is 13 chars: 2 (prefix) + 11 (hash) = 13
CLUSTER_NAME="ci$(echo -n $PROW_JOB_ID|sha256sum|cut -c-11)"

# Save cluster name early so destroy step can clean up if we fail partway through
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

echo "Hosted Cluster Project: ${HC_PROJECT_ID}"
echo "Region: ${GCP_REGION}"
echo "Cluster Name (Infra ID): ${CLUSTER_NAME}"

# Set the project
gcloud config set project "${HC_PROJECT_ID}"

# =============================================================================
# Step 1: Generate RSA Keypair for Service Account Token Signing
# =============================================================================
# Note: Tracing disabled for key generation to avoid exposing key material
# Note: Files stored directly in SHARED_DIR (not subdirectory) to ensure sync between steps
echo "=== Step 1: Generate RSA Keypair ==="

SA_SIGNER_KEY="${SHARED_DIR}/hc-sa-signer.key"
SA_SIGNER_PUB="${SHARED_DIR}/hc-sa-signer.pub"
JWKS_FILE="${SHARED_DIR}/hc-jwks.json"

# Generate RSA private key in PKCS#1 format
# OpenSSL 3.x may produce PKCS#8 format, but HyperShift requires PKCS#1
# Use 'openssl rsa -traditional' to ensure PKCS#1 output (BEGIN RSA PRIVATE KEY)
# Reference: gcp-hcp-archived/experiments/wif-example/hosted-cluster-setup/1-generate-sa-signing-key.sh
echo "OpenSSL version: $(openssl version)"

# Step 1: Generate RSA private key
openssl genrsa -out "${SA_SIGNER_KEY}.tmp" 4096

# Step 2: Convert to PKCS#1 format using -traditional flag
openssl rsa -in "${SA_SIGNER_KEY}.tmp" -out "${SA_SIGNER_KEY}" -traditional

# Step 3: Clean up temporary file
rm -f "${SA_SIGNER_KEY}.tmp"

# Verify key was generated correctly
if [[ ! -s "${SA_SIGNER_KEY}" ]]; then
    echo "ERROR: Generated key file is empty"
    exit 1
fi

# Verify key format is PKCS#1
KEY_HEADER=$(head -1 "${SA_SIGNER_KEY}")
echo "Key format: ${KEY_HEADER}"
if [[ "${KEY_HEADER}" != "-----BEGIN RSA PRIVATE KEY-----" ]]; then
    echo "ERROR: Key has unexpected format: ${KEY_HEADER}"
    echo "Expected: -----BEGIN RSA PRIVATE KEY----- (PKCS#1)"
    exit 1
fi

echo "Generated PKCS#1 RSA private key (4096 bits)"

# Extract public key
openssl rsa -in "${SA_SIGNER_KEY}" -pubout -out "${SA_SIGNER_PUB}" 2>/dev/null

# Create JWKS file from public key
# Get the modulus and exponent in base64url format
# Note: Using printf '%b' instead of xxd (xxd not available in hypershift-operator image)
# Note: Strip leading '00' byte - openssl adds it when high bit is set, but JWK spec requires minimum octets
HEX_MODULUS=$(openssl rsa -in "${SA_SIGNER_KEY}" -pubout -outform DER 2>/dev/null | \
  openssl rsa -pubin -inform DER -text -noout 2>/dev/null | \
  grep -A 100 "^Modulus:" | grep -v "^Modulus:" | grep -v "^Exponent:" | \
  tr -d ' \n:' | sed 's/^00//')
MODULUS=$(printf '%b' "$(echo "$HEX_MODULUS" | sed 's/../\\x&/g')" | base64 -w0 | tr '+/' '-_' | tr -d '=')


# Calculate kid as SHA256 of DER-encoded public key, base64url encoded
# This matches the industry standard used by Kubernetes API server and gcp-hcp-cli
KID=$(openssl rsa -in "${SA_SIGNER_KEY}" -pubout -outform DER 2>/dev/null | \
  openssl dgst -sha256 -binary | \
  base64 -w0 | tr '+/' '-_' | tr -d '=')

# Create JWKS JSON
cat > "${JWKS_FILE}" << EOF
{
  "keys": [
    {
      "kty": "RSA",
      "alg": "RS256",
      "use": "sig",
      "kid": "${KID}",
      "n": "${MODULUS}",
      "e": "AQAB"
    }
  ]
}
EOF

echo "RSA keypair generated successfully"

# Save signing key path for run-e2e step
echo "${SA_SIGNER_KEY}" > "${SHARED_DIR}/sa-signing-key-path"

# Enable tracing for remaining steps (non-sensitive)
set -x

# =============================================================================
# Step 2: Create IAM/WIF Infrastructure
# =============================================================================
echo "=== Step 2: Create IAM/WIF Infrastructure ==="

IAM_OUTPUT="${SHARED_DIR}/iam-config.json"

hypershift create iam gcp \
  --infra-id="${CLUSTER_NAME}" \
  --project-id="${HC_PROJECT_ID}" \
  --oidc-jwks-file="${JWKS_FILE}" \
  > "${IAM_OUTPUT}"

echo "IAM/WIF infrastructure created"
cat "${IAM_OUTPUT}"

# Extract WIF configuration for run-e2e step
# Using awk instead of jq (jq not available and can't install in non-root container)
PROJECT_NUMBER=$(awk -F'"' '/"projectNumber"/{print $4}' "${IAM_OUTPUT}")
POOL_ID=$(awk -F'"' '/"poolId"/{print $4}' "${IAM_OUTPUT}")
PROVIDER_ID=$(awk -F'"' '/"providerId"/{print $4}' "${IAM_OUTPUT}")
CONTROLPLANE_SA=$(awk -F'"' '/"ctrlplane-op"/{print $4}' "${IAM_OUTPUT}")
NODEPOOL_SA=$(awk -F'"' '/"nodepool-mgmt"/{print $4}' "${IAM_OUTPUT}")
CLOUDCONTROLLER_SA=$(awk -F'"' '/"cloud-controller"/{print $4}' "${IAM_OUTPUT}")
STORAGE_SA=$(awk -F'"' '/"gcp-pd-csi"/{print $4}' "${IAM_OUTPUT}")

# Save to SHARED_DIR for run-e2e step
echo "${PROJECT_NUMBER}" > "${SHARED_DIR}/wif-project-number"
echo "${POOL_ID}" > "${SHARED_DIR}/wif-pool-id"
echo "${PROVIDER_ID}" > "${SHARED_DIR}/wif-provider-id"
echo "${CONTROLPLANE_SA}" > "${SHARED_DIR}/controlplane-sa"
echo "${NODEPOOL_SA}" > "${SHARED_DIR}/nodepool-sa"
echo "${CLOUDCONTROLLER_SA}" > "${SHARED_DIR}/cloudcontroller-sa"
echo "${STORAGE_SA}" > "${SHARED_DIR}/storage-sa"

echo "WIF configuration saved to SHARED_DIR"

# =============================================================================
# Step 3: Create Network Infrastructure
# =============================================================================
echo "=== Step 3: Create Network Infrastructure ==="

INFRA_OUTPUT="${SHARED_DIR}/infra-config.json"

hypershift create infra gcp \
  --infra-id="${CLUSTER_NAME}" \
  --project-id="${HC_PROJECT_ID}" \
  --region="${GCP_REGION}" \
  > "${INFRA_OUTPUT}"

echo "Network infrastructure created"
cat "${INFRA_OUTPUT}"

# Extract network configuration (these may override what hypershift-gcp-gke-provision created)
# Using awk instead of jq (jq not available in hypershift-operator image)
HC_VPC_NAME=$(awk -F'"' '/"networkName"/{print $4}' "${INFRA_OUTPUT}")
HC_SUBNET_NAME=$(awk -F'"' '/"subnetName"/{print $4}' "${INFRA_OUTPUT}")

# Save HC-specific network info to SHARED_DIR
echo "${HC_VPC_NAME}" > "${SHARED_DIR}/hc-vpc-name"
echo "${HC_SUBNET_NAME}" > "${SHARED_DIR}/hc-subnet-name"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Infrastructure Setup Complete ==="
echo "Hosted Cluster Project: ${HC_PROJECT_ID}"
echo "Region: ${GCP_REGION}"
echo "Cluster Name: ${CLUSTER_NAME}"
echo ""
echo "WIF Configuration:"
echo "  Project Number: ${PROJECT_NUMBER}"
echo "  Pool ID: ${POOL_ID}"
echo "  Provider ID: ${PROVIDER_ID}"
echo "  Control Plane SA: ${CONTROLPLANE_SA}"
echo "  NodePool SA: ${NODEPOOL_SA}"
echo "  Cloud Controller SA: ${CLOUDCONTROLLER_SA}"
echo ""
echo "Network Configuration:"
echo "  VPC: ${HC_VPC_NAME}"
echo "  Subnet: ${HC_SUBNET_NAME}"
