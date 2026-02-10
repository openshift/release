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

# ============================================================================
# Step 5: Create static kubeconfig with GCP access token
# This avoids requiring gcloud/auth-plugin installation in downstream steps.
# The access token is valid for ~60 minutes, sufficient for CI jobs.
# ============================================================================
echo "Creating static kubeconfig with embedded access token"

# Disable tracing to protect sensitive values (access token)
set +x

CLUSTER_CA=$(gcloud container clusters describe "${CLUSTER_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --format="value(masterAuth.clusterCaCertificate)")
CLUSTER_ENDPOINT=$(gcloud container clusters describe "${CLUSTER_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --format="value(endpoint)")
ACCESS_TOKEN=$(gcloud auth print-access-token)

cat > "${SHARED_DIR}/kubeconfig" << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CLUSTER_CA}
    server: https://${CLUSTER_ENDPOINT}
  name: gke-cluster
contexts:
- context:
    cluster: gke-cluster
    user: gke-user
  name: gke-context
current-context: gke-context
users:
- name: gke-user
  user:
    token: ${ACCESS_TOKEN}
EOF

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
echo "Kubeconfig created successfully"

# Re-enable tracing
set -x

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
