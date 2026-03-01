#!/usr/bin/env bash

set -euo pipefail

# This step configures the HyperShift control plane on GKE:
# 1. TLS certificate for operator webhooks (via cert-manager)
# 2. HyperShift operator WIF - PSC operations (create/manage service attachments)
# 3. ExternalDNS WIF - DNS record management via cross-project WIF

echo "Starting GCP Workload Identity setup..."

# Load GCP credentials and project info (before set -x to protect secrets)
GCP_CREDS_FILE="${CLUSTER_PROFILE_DIR}/credentials.json"
CP_PROJECT_ID="$(<"${SHARED_DIR}/control-plane-project-id")"
EXTERNAL_DNS_GSA="external-dns@${HYPERSHIFT_GCP_CI_PROJECT}.iam.gserviceaccount.com"

# Authenticate with GCP
gcloud auth activate-service-account --key-file="${GCP_CREDS_FILE}"
gcloud config set project "${CP_PROJECT_ID}"

# Service account name
SA_NAME="hypershift-operator"
SA_EMAIL="${SA_NAME}@${CP_PROJECT_ID}.iam.gserviceaccount.com"

# Custom role name and permissions (from workload-identity.yaml)
ROLE_NAME="hypershiftPSCOperator"
ROLE_PERMISSIONS="compute.forwardingRules.list,compute.forwardingRules.use,compute.serviceAttachments.create,compute.serviceAttachments.delete,compute.serviceAttachments.get,compute.serviceAttachments.list,compute.subnetworks.list,compute.subnetworks.use,compute.regionOperations.get"

# Enable tracing for non-sensitive operations
set -x

# ============================================================================
# Step 1: Create TLS certificate for operator webhooks (via cert-manager)
# ============================================================================
echo "Creating TLS certificate for operator webhooks..."
cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: manager-serving-cert
  namespace: hypershift
spec:
  secretName: manager-serving-cert
  duration: 8760h
  commonName: hypershift-operator
  dnsNames:
  - hypershift-operator
  - hypershift-operator.hypershift
  - hypershift-operator.hypershift.svc
  - hypershift-operator.hypershift.svc.cluster.local
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
    group: cert-manager.io
EOF

# Wait for the certificate secret to be created and operator to become available
echo "Waiting for operator deployment to become available..."
oc rollout status deployment/operator -n hypershift --timeout=300s
oc wait --for=condition=Available --namespace hypershift deployments/operator --timeout=300s

# ============================================================================
# Step 2: Create GCP Service Account for PSC
# ============================================================================
echo "Creating GCP service account: ${SA_NAME}"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project="${CP_PROJECT_ID}" &>/dev/null; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --display-name="HyperShift Operator" \
    --description="Service account for HyperShift operator to access GCP resources"
else
  echo "Service account ${SA_EMAIL} already exists, skipping creation"
fi

# ============================================================================
# Step 3: Create Custom IAM Role for PSC Operations
# ============================================================================
echo "Creating custom IAM role: ${ROLE_NAME}"
if ! gcloud iam roles describe "${ROLE_NAME}" --project="${CP_PROJECT_ID}" &>/dev/null; then
  gcloud iam roles create "${ROLE_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --title="HyperShift PSC Operator" \
    --description="Minimal permissions for HyperShift Private Service Connect operations" \
    --permissions="${ROLE_PERMISSIONS}" \
    --stage="GA"
else
  echo "Custom role ${ROLE_NAME} already exists, skipping creation"
fi

# ============================================================================
# Step 4: Bind Custom Role to Service Account
# ============================================================================
echo "Binding custom role to service account"
gcloud projects add-iam-policy-binding "${CP_PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="projects/${CP_PROJECT_ID}/roles/${ROLE_NAME}" \
  --condition=None \
  --quiet

# ============================================================================
# Step 5: Configure Workload Identity Binding
# ============================================================================
echo "Configuring Workload Identity binding"
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${CP_PROJECT_ID}" \
  --member="serviceAccount:${CP_PROJECT_ID}.svc.id.goog[hypershift/operator]" \
  --role="roles/iam.workloadIdentityUser" \
  --condition=None \
  --quiet

# ============================================================================
# Step 6: Annotate K8s ServiceAccount for Workload Identity
# ============================================================================
echo "Annotating K8s ServiceAccount for Workload Identity"
oc annotate serviceaccount operator -n hypershift \
  "iam.gke.io/gcp-service-account=${SA_EMAIL}" \
  --overwrite

# Restart the operator to pick up the new annotation
echo "Restarting operator deployment to pick up Workload Identity"
oc rollout restart deployment/operator -n hypershift
oc rollout status deployment/operator -n hypershift --timeout=300s

# ============================================================================
# Step 7: Configure ExternalDNS Workload Identity
# ExternalDNS uses a dedicated GCP SA in the CI project with roles/dns.admin,
# authenticated via cross-project GKE Workload Identity.
# ============================================================================
echo "Configuring ExternalDNS Workload Identity..."

# Create WIF bindings: allow this ephemeral GKE cluster's K8s SA to impersonate the GCP SA
# Cross-project WIF requires both workloadIdentityUser and serviceAccountTokenCreator
# Tracing disabled to protect project ID in the member string
set +x
WIF_MEMBER="serviceAccount:${CP_PROJECT_ID}.svc.id.goog[hypershift/external-dns]"
gcloud iam service-accounts add-iam-policy-binding "${EXTERNAL_DNS_GSA}" \
  --role=roles/iam.workloadIdentityUser \
  --member="${WIF_MEMBER}" \
  --project="${HYPERSHIFT_GCP_CI_PROJECT}" \
  --condition=None \
  --quiet
gcloud iam service-accounts add-iam-policy-binding "${EXTERNAL_DNS_GSA}" \
  --role=roles/iam.serviceAccountTokenCreator \
  --member="${WIF_MEMBER}" \
  --project="${HYPERSHIFT_GCP_CI_PROJECT}" \
  --condition=None \
  --quiet
set -x

# Annotate K8s SA for Workload Identity and restart ExternalDNS
oc annotate serviceaccount external-dns -n hypershift \
  "iam.gke.io/gcp-service-account=${EXTERNAL_DNS_GSA}" \
  --overwrite

oc rollout restart deployment/external-dns -n hypershift
echo "Waiting for ExternalDNS rollout..."
oc rollout status deployment/external-dns -n hypershift --timeout=300s

echo "GCP Workload Identity setup complete"
