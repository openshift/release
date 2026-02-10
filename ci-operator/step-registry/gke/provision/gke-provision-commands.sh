#!/usr/bin/env bash

set -euo pipefail

# Load GCP credentials from cluster profile
GCP_CREDS_FILE="${CLUSTER_PROFILE_DIR}/credentials.json"
CI_FOLDER_ID="$(<"${CLUSTER_PROFILE_DIR}/ci-folder-id")"
BILLING_ACCOUNT_ID="$(<"${CLUSTER_PROFILE_DIR}/billing-account-id")"
GCP_REGION="${GKE_REGION:-us-central1}"
RELEASE_CHANNEL="${GKE_RELEASE_CHANNEL:-stable}"

# Authenticate with GCP (before set -x to avoid exposing credentials path)
gcloud auth activate-service-account --key-file="${GCP_CREDS_FILE}"

# Create and save the GKE auth plugin install script to SHARED_DIR
# This script is reused by subsequent steps (hypershift-install, run-e2e)
# Note: gcloud components install is disabled in upi-installer image (installed via yum)
# so we download the plugin binary directly
cat > "${SHARED_DIR}/install-gke-auth-plugin.sh" << 'INSTALL_SCRIPT'
#!/usr/bin/env bash
# Install GKE auth plugin (required for kubectl/oc authentication with GKE)
# Source: Google's official package distribution (dl.google.com)
# Checksum from: https://aur.archlinux.org/packages/google-cloud-cli-gke-gcloud-auth-plugin
set -euo pipefail

GKE_AUTH_PLUGIN_VERSION="542.0.0"
GKE_AUTH_PLUGIN_SHA256="b8fb245a2f2112c3f7f45f9482cba82936e26a52d6376683e8ea9b27f053958d"
GKE_AUTH_PLUGIN_URL="https://dl.google.com/dl/cloudsdk/release/downloads/for_packagers/linux/google-cloud-cli-gke-gcloud-auth-plugin_${GKE_AUTH_PLUGIN_VERSION}.orig_amd64.tar.gz"

# Allow caller to specify install directory, default to ${HOME}/bin
INSTALL_DIR="${GKE_AUTH_PLUGIN_INSTALL_DIR:-${HOME}/bin}"

echo "Installing gke-gcloud-auth-plugin v${GKE_AUTH_PLUGIN_VERSION} to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
PLUGIN_TARBALL=$(mktemp)
curl -sL "${GKE_AUTH_PLUGIN_URL}" -o "${PLUGIN_TARBALL}"

echo "Verifying checksum..."
echo "${GKE_AUTH_PLUGIN_SHA256}  ${PLUGIN_TARBALL}" | sha256sum -c -

tar -xzf "${PLUGIN_TARBALL}" -C "${INSTALL_DIR}" --strip-components=2 google-cloud-sdk/bin/gke-gcloud-auth-plugin
rm -f "${PLUGIN_TARBALL}"
chmod +x "${INSTALL_DIR}/gke-gcloud-auth-plugin"

echo "gke-gcloud-auth-plugin installed successfully"
INSTALL_SCRIPT

chmod +x "${SHARED_DIR}/install-gke-auth-plugin.sh"

# Run the install script for this step
"${SHARED_DIR}/install-gke-auth-plugin.sh"
export PATH="${PATH}:${HOME}/bin"
export USE_GKE_GCLOUD_AUTH_PLUGIN=True


gcloud --version

# Generate unique resource name prefix (following AKS pattern)
RESOURCE_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
CLUSTER_NAME="${RESOURCE_NAME_PREFIX}-gke"
INFRA_ID="${RESOURCE_NAME_PREFIX}"

# Dynamic project IDs (created per-test)
# Truncate to meet GCP's 30 character limit for project IDs
MGMT_PROJECT_ID="${INFRA_ID:0:25}-mgmt"
CUSTOMER_PROJECT_ID="${INFRA_ID:0:25}-cust"

# ============================================================================
# Step 1: Create Dynamic Projects (under CI folder)
# NOTE: These commands run without tracing to protect CI_FOLDER_ID and BILLING_ACCOUNT_ID
# ============================================================================
echo "Creating management project: ${MGMT_PROJECT_ID}"
gcloud projects create "${MGMT_PROJECT_ID}" \
    --folder="${CI_FOLDER_ID}" \
    --quiet

echo "Creating customer project: ${CUSTOMER_PROJECT_ID}"
gcloud projects create "${CUSTOMER_PROJECT_ID}" \
    --folder="${CI_FOLDER_ID}" \
    --quiet

# Link projects to billing account (sensitive - billing account ID)
echo "Linking projects to billing account"
gcloud billing projects link "${MGMT_PROJECT_ID}" \
    --billing-account="${BILLING_ACCOUNT_ID}"
gcloud billing projects link "${CUSTOMER_PROJECT_ID}" \
    --billing-account="${BILLING_ACCOUNT_ID}"

# Enable tracing for remaining operations (no secrets exposed below)
set -x

# Enable required APIs in management project
echo "Enabling APIs in management project"
gcloud services enable \
    container.googleapis.com \
    compute.googleapis.com \
    cloudresourcemanager.googleapis.com \
    --project="${MGMT_PROJECT_ID}"

# Enable required APIs in customer project
echo "Enabling APIs in customer project"
gcloud services enable \
    compute.googleapis.com \
    dns.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    cloudresourcemanager.googleapis.com \
    --project="${CUSTOMER_PROJECT_ID}"

# Wait for API enablement to propagate
echo "Waiting for API enablement to propagate..."
sleep 30

gcloud config set project "${MGMT_PROJECT_ID}"

# ============================================================================
# Step 2: Create VPC and networking in management project
# ============================================================================
VPC_NAME="${INFRA_ID}-vpc"
GKE_SUBNET_NAME="${INFRA_ID}-gke-subnet"
PSC_SUBNET_NAME="${INFRA_ID}-psc"

echo "Creating VPC in management project"
gcloud compute networks create "${VPC_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --subnet-mode=custom \
    --quiet

echo "Creating GKE subnet"
gcloud compute networks subnets create "${GKE_SUBNET_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --range="10.0.0.0/20" \
    --secondary-range="gke-pods=10.4.0.0/14,gke-services=10.8.0.0/20" \
    --enable-private-ip-google-access \
    --quiet

echo "Creating Cloud Router and NAT"
gcloud compute routers create "${INFRA_ID}-router" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --quiet

gcloud compute routers nats create "${INFRA_ID}-nat" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --router="${INFRA_ID}-router" \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips \
    --quiet

# ============================================================================
# Step 3: Add PSC Subnet to VPC (for Service Attachments)
# ============================================================================
echo "Creating PSC subnet: ${PSC_SUBNET_NAME}"
gcloud compute networks subnets create "${PSC_SUBNET_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --range="10.3.0.0/24" \
    --purpose=PRIVATE_SERVICE_CONNECT \
    --quiet

# ============================================================================
# Step 4: Create GKE Autopilot Cluster
# ============================================================================
echo "Creating GKE Autopilot cluster: ${CLUSTER_NAME}"
gcloud container clusters create-auto "${CLUSTER_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --subnetwork="${GKE_SUBNET_NAME}" \
    --cluster-secondary-range-name="gke-pods" \
    --services-secondary-range-name="gke-services" \
    --release-channel="${RELEASE_CHANNEL}" \
    --quiet

echo "Getting kubeconfig"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}"

# Save cluster info for deprovision step and downstream steps
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
echo "${MGMT_PROJECT_ID}" > "${SHARED_DIR}/mgmt-project-id"
echo "${CUSTOMER_PROJECT_ID}" > "${SHARED_DIR}/customer-project-id"
echo "${GCP_REGION}" > "${SHARED_DIR}/gcp-region"
echo "${INFRA_ID}" > "${SHARED_DIR}/infra-id"
echo "${VPC_NAME}" > "${SHARED_DIR}/vpc-name"
echo "${PSC_SUBNET_NAME}" > "${SHARED_DIR}/psc-subnet"

# Verify cluster access
oc get nodes
oc version

echo "GKE management cluster provisioned successfully"
