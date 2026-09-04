#!/usr/bin/env bash

set -euo pipefail

CI_FOLDER_ID="$(<"${CLUSTER_PROFILE_DIR}/ci-folder-id")"
BILLING_ACCOUNT_ID="$(<"${CLUSTER_PROFILE_DIR}/billing-account-id")"
GCP_REGION="${GKE_REGION:-us-central1}"
RELEASE_CHANNEL="${GKE_RELEASE_CHANNEL:-stable}"

# Authenticate with GCP via WIF credential written by hypershift-gcp-wif-auth step
gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json"

gcloud --version

# Generate unique resource name prefix (following AKS pattern)
RESOURCE_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
CLUSTER_NAME="${RESOURCE_NAME_PREFIX}-gke"
INFRA_ID="${RESOURCE_NAME_PREFIX}"

# Dynamic project IDs (created per-test)
# Use BUILD_ID (unique per Prow job) to avoid project ID collisions between
# concurrent tests sharing the same NAMESPACE and UNIQUE_HASH (e.g. e2e-gke and e2e-v2-gke).
# Prefix with "ci" to satisfy GCP's requirement that project IDs start with a letter.
# Result: "ci" + 8 hex chars + suffix = 24-25 chars, under the 30-char GCP limit.
PROJECT_HASH="ci$(echo -n "${BUILD_ID}" | sha256sum | cut -c1-8)"
CP_PROJECT_ID="${PROJECT_HASH}-control-plane"
HC_PROJECT_ID="${PROJECT_HASH}-hosted-cluster"

# Write deprovision-critical values to SHARED_DIR before creating any resources,
# so the deprovision step can clean up if the step fails or the job is interrupted.
# Deprovision handles non-existent projects gracefully (|| true).
echo "${GCP_REGION}" > "${SHARED_DIR}/gcp-region"
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/control-plane-cluster-name"
echo "${CP_PROJECT_ID}" > "${SHARED_DIR}/control-plane-project-id"
echo "${HC_PROJECT_ID}" > "${SHARED_DIR}/hosted-cluster-project-id"

# ============================================================================
# Step 1: Create Dynamic Projects (under CI folder)
# NOTE: These commands run without tracing to protect CI_FOLDER_ID and BILLING_ACCOUNT_ID
# ============================================================================
echo "Creating Control Plane project: ${CP_PROJECT_ID}"
gcloud projects create "${CP_PROJECT_ID}" \
    --folder="${CI_FOLDER_ID}" \
    --quiet

echo "Creating Hosted Cluster project: ${HC_PROJECT_ID}"
gcloud projects create "${HC_PROJECT_ID}" \
    --folder="${CI_FOLDER_ID}" \
    --quiet

# Link projects to billing account (sensitive - billing account ID)
echo "Linking projects to billing account"
gcloud billing projects link "${CP_PROJECT_ID}" \
    --billing-account="${BILLING_ACCOUNT_ID}"
gcloud billing projects link "${HC_PROJECT_ID}" \
    --billing-account="${BILLING_ACCOUNT_ID}"

# Enable tracing for remaining operations (no secrets exposed below)
set -x

# Enable required APIs in Control Plane project
echo "Enabling APIs in Control Plane project"
gcloud services enable \
    container.googleapis.com \
    compute.googleapis.com \
    cloudresourcemanager.googleapis.com \
    --project="${CP_PROJECT_ID}"

# Enable required APIs in Hosted Cluster project
echo "Enabling APIs in Hosted Cluster project"
gcloud services enable \
    compute.googleapis.com \
    dns.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    cloudresourcemanager.googleapis.com \
    storage.googleapis.com \
    --project="${HC_PROJECT_ID}"

# GCP API enablement is eventually consistent: gcloud services enable returns
# immediately but API calls may fail briefly. 30s is empirically sufficient.
# If this becomes flaky, consider polling actual API calls to verify serving
# readiness rather than just enablement state.
echo "Waiting for API enablement to propagate..."
sleep 30

gcloud config set project "${CP_PROJECT_ID}"

# ============================================================================
# Step 2: Create VPC and networking in Control Plane project
# ============================================================================
VPC_NAME="${INFRA_ID}-vpc"
GKE_SUBNET_NAME="${INFRA_ID}-gke-subnet"
PSC_SUBNET_NAME="${INFRA_ID}-psc"

echo "Creating VPC in Control Plane project"
gcloud compute networks create "${VPC_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --subnet-mode=custom \
    --quiet

echo "Creating GKE subnet"
gcloud compute networks subnets create "${GKE_SUBNET_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --range="10.0.0.0/20" \
    --secondary-range="gke-pods=10.4.0.0/14,gke-services=10.8.0.0/20" \
    --enable-private-ip-google-access \
    --quiet

echo "Creating Cloud Router and NAT"
gcloud compute routers create "${INFRA_ID}-router" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --quiet

gcloud compute routers nats create "${INFRA_ID}-nat" \
    --project="${CP_PROJECT_ID}" \
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
    --project="${CP_PROJECT_ID}" \
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
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --subnetwork="${GKE_SUBNET_NAME}" \
    --cluster-secondary-range-name="gke-pods" \
    --services-secondary-range-name="gke-services" \
    --release-channel="${RELEASE_CHANNEL}" \
    --enable-private-nodes \
    --quiet

# ============================================================================
# Step 5: Create a cluster-local kubeconfig for the Control Plane cluster
# This kubeconfig provides access to the GKE cluster where HyperShift operator
# runs and Hosted Cluster control planes are deployed.
# Google authentication is used only to bootstrap a dedicated Kubernetes
# ServiceAccount. Downstream steps use its 12-hour TokenRequest credential and
# do not require gcloud or an authentication plugin.
# ============================================================================
echo "Creating cluster-local kubeconfig"

# Use a subshell function so credential variables cannot leak into the rest of
# the step. Tracing is disabled only inside the subshell; the parent retains its
# tracing state.
create_cluster_local_kubeconfig() (
  set +x

  local cluster_ca
  local cluster_endpoint
  local gcp_bootstrap_token
  local bootstrap_kubeconfig
  local token_request_duration="12h"
  local ci_admin_token_request
  local ci_admin_token
  local ci_admin_token_expiration
  local authenticated_identity

  cluster_ca=$(gcloud container clusters describe "${CLUSTER_NAME}" \
      --project="${CP_PROJECT_ID}" \
      --region="${GCP_REGION}" \
      --format="value(masterAuth.clusterCaCertificate)")
  cluster_endpoint=$(gcloud container clusters describe "${CLUSTER_NAME}" \
      --project="${CP_PROJECT_ID}" \
      --region="${GCP_REGION}" \
      --format="value(endpoint)")
  if ! gcp_bootstrap_token=$(gcloud auth print-access-token); then
    echo "ERROR: Failed to obtain GCP OAuth bootstrap token"
    exit 1
  fi
  bootstrap_kubeconfig=$(mktemp "${TMPDIR:-/tmp}/gke-bootstrap-kubeconfig.XXXXXX")
  trap 'rm -f -- "${bootstrap_kubeconfig}"' EXIT

  cat > "${bootstrap_kubeconfig}" << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${cluster_ca}
    server: https://${cluster_endpoint}
  name: gke-control-plane-cluster
contexts:
- context:
    cluster: gke-control-plane-cluster
    user: gcp-bootstrap
  name: gke-control-plane-cluster
current-context: gke-control-plane-cluster
users:
- name: gcp-bootstrap
  user:
    token: ${gcp_bootstrap_token}
EOF
  chmod 600 "${bootstrap_kubeconfig}"

  oc --kubeconfig="${bootstrap_kubeconfig}" create namespace hypershift-ci
  oc --kubeconfig="${bootstrap_kubeconfig}" create serviceaccount ci-admin -n hypershift-ci
  oc --kubeconfig="${bootstrap_kubeconfig}" create clusterrolebinding ci-admin \
      --clusterrole=cluster-admin \
      --serviceaccount=hypershift-ci:ci-admin

  if ! ci_admin_token_request=$(oc --kubeconfig="${bootstrap_kubeconfig}" create token ci-admin \
      -n hypershift-ci \
      --duration="${token_request_duration}" \
      -o json); then
    echo "ERROR: Failed to create ci-admin Kubernetes ServiceAccount token"
    exit 1
  fi

  if ! ci_admin_token=$(jq -er '.status.token | select(type == "string" and length > 0)' <<<"${ci_admin_token_request}") || \
     ! ci_admin_token_expiration=$(jq -er '.status.expirationTimestamp | select(type == "string" and length > 0)' <<<"${ci_admin_token_request}"); then
    echo "ERROR: Failed to parse ci-admin Kubernetes TokenRequest response"
    exit 1
  fi

  echo "ci-admin token expiration: ${ci_admin_token_expiration}"

  # Control Plane cluster kubeconfig - filename follows CI convention.
  # Used by subsequent workflow steps that need access to the Control Plane cluster.
  cat > "${SHARED_DIR}/kubeconfig" << EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${cluster_ca}
    server: https://${cluster_endpoint}
  name: gke-control-plane-cluster
contexts:
- context:
    cluster: gke-control-plane-cluster
    user: ci-admin
  name: gke-control-plane-cluster
current-context: gke-control-plane-cluster
users:
- name: ci-admin
  user:
    token: ${ci_admin_token}
EOF
  chmod 600 "${SHARED_DIR}/kubeconfig"

  if ! authenticated_identity=$(oc --kubeconfig="${SHARED_DIR}/kubeconfig" auth whoami \
      -o jsonpath='{.status.userInfo.username}'); then
    echo "ERROR: Failed to authenticate with the ci-admin Kubernetes ServiceAccount kubeconfig"
    exit 1
  fi
  if [[ "${authenticated_identity}" != "system:serviceaccount:hypershift-ci:ci-admin" ]]; then
    echo "ERROR: Unexpected identity for the ci-admin Kubernetes ServiceAccount kubeconfig: ${authenticated_identity}"
    exit 1
  fi
  echo "Kubernetes authenticated identity: ${authenticated_identity}"
  echo "Kubeconfig created successfully"

  rm -f -- "${bootstrap_kubeconfig}"
  trap - EXIT
)

create_cluster_local_kubeconfig
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Save remaining cluster info for downstream steps
echo "${INFRA_ID}" > "${SHARED_DIR}/infra-id"
echo "${VPC_NAME}" > "${SHARED_DIR}/vpc-name"
echo "${PSC_SUBNET_NAME}" > "${SHARED_DIR}/psc-subnet"

# CI DNS config for hypershift-install (shared step, can't use workflow env vars)
echo "${HYPERSHIFT_GCP_CI_PROJECT}" > "${SHARED_DIR}/hypershift-ci-project"
echo "${HYPERSHIFT_GCP_CI_DNS_DOMAIN}" > "${SHARED_DIR}/hypershift-ci-dns-domain"

# Verify cluster access
oc get nodes
oc version

echo "GKE Control Plane cluster provisioned successfully"
