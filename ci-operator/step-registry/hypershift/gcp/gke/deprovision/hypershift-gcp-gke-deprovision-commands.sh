#!/usr/bin/env bash

set -euo pipefail

# Load GCP credentials from cluster profile
GCP_CREDS_FILE="${CLUSTER_PROFILE_DIR}/credentials.json"
gcloud auth activate-service-account --key-file="${GCP_CREDS_FILE}"

# Check if provision completed - if not, nothing to clean up
if [[ ! -f "${SHARED_DIR}/control-plane-project-id" ]]; then
    echo "No control-plane-project-id file found - provision may not have completed"
    echo "Nothing to deprovision, exiting successfully"
    exit 0
fi

# Load cluster info from provision step
CP_PROJECT_ID="$(<"${SHARED_DIR}/control-plane-project-id")"
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
GCP_REGION="$(<"${SHARED_DIR}/gcp-region")"

# Hosted Cluster project file path (may not exist if provision failed early)
HC_PROJECT_FILE="${SHARED_DIR}/hosted-cluster-project-id"
if [[ -f "${HC_PROJECT_FILE}" ]]; then
    HC_PROJECT_ID="$(<"${HC_PROJECT_FILE}")"
else
    HC_PROJECT_ID=""
fi

set -x

# ============================================================================
# Cleanup Strategy (project deletion first, then CI resource cleanup):
# 1. Delete Hosted Cluster project (removes cross-project PSC references)
# 2. Delete GKE cluster (has finalizers, must complete before project deletion)
# 3. Delete Control Plane project (handles remaining VPCs, firewall rules)
# 4. Clean up CI resources (DNS records, WIF bindings) - independent of projects
#
# We use --async + polling for GKE deletion for explicit control over
# completion status and better timeout handling.
# ============================================================================

# ----------------------------------------------------------------------------
# Step 1: Delete Hosted Cluster project (if it exists)
# Delete first to remove any cross-project dependencies (PSC endpoints, etc.)
# ----------------------------------------------------------------------------
if [[ -n "${HC_PROJECT_ID}" ]]; then
    echo "Deleting Hosted Cluster project: ${HC_PROJECT_ID}"
    gcloud projects delete "${HC_PROJECT_ID}" --quiet || true
else
    echo "No Hosted Cluster project to clean up"
fi

# ----------------------------------------------------------------------------
# Step 2: Delete GKE cluster
# Using --async + polling for explicit control over completion
# ----------------------------------------------------------------------------
echo "Deleting GKE Control Plane cluster: ${CLUSTER_NAME}"
gcloud container clusters delete "${CLUSTER_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --async \
    --quiet || true

# Poll for cluster deletion (60 attempts x 10s = 10 minutes max wait)
echo "Waiting for GKE cluster deletion to complete..."
for i in {1..60}; do
    if ! gcloud container clusters describe "${CLUSTER_NAME}" \
        --project="${CP_PROJECT_ID}" \
        --region="${GCP_REGION}" >/dev/null 2>&1; then
        echo "GKE cluster deleted successfully"
        break
    fi
    echo "Waiting for GKE cluster deletion... (attempt $i/60)"
    sleep 10
done

# ----------------------------------------------------------------------------
# Step 3: Delete Control Plane project
# ----------------------------------------------------------------------------
echo "Deleting Control Plane project: ${CP_PROJECT_ID}"
gcloud projects delete "${CP_PROJECT_ID}" --quiet || true

# ----------------------------------------------------------------------------
# Step 4: Clean up CI resources (DNS records and WIF bindings)
# These are in the persistent CI project, independent of the ephemeral projects
# ----------------------------------------------------------------------------

# CI DNS config (from workflow env vars)
EXTERNAL_DNS_GSA="external-dns@${HYPERSHIFT_GCP_CI_PROJECT}.iam.gserviceaccount.com"

# Clean up DNS records from the CI zone
echo "Cleaning up DNS records for cluster ${CLUSTER_NAME}..."
DNS_SUFFIX="in.${CLUSTER_NAME}.${HYPERSHIFT_GCP_CI_DNS_DOMAIN}."
DNS_RECORDS=$(gcloud dns record-sets list \
  --zone="${HYPERSHIFT_GCP_CI_DNS_ZONE}" \
  --project="${HYPERSHIFT_GCP_CI_PROJECT}" \
  --filter="name ~ ${DNS_SUFFIX}" \
  --format="csv[no-heading](name,type)" 2>/dev/null || true)

if [[ -n "${DNS_RECORDS}" ]]; then
  while IFS=, read -r name type; do
    [[ -z "${name}" ]] && continue
    echo "Deleting DNS record: ${name} ${type}"
    gcloud dns record-sets delete "${name}" \
      --type="${type}" \
      --zone="${HYPERSHIFT_GCP_CI_DNS_ZONE}" \
      --project="${HYPERSHIFT_GCP_CI_PROJECT}" --quiet || true
  done <<< "${DNS_RECORDS}"
else
  echo "No DNS records found matching ${DNS_SUFFIX}"
fi

# Remove ExternalDNS WIF bindings
echo "Removing ExternalDNS WIF bindings for project ${CP_PROJECT_ID}..."
set +x
WIF_MEMBER="serviceAccount:${CP_PROJECT_ID}.svc.id.goog[hypershift/external-dns]"
gcloud iam service-accounts remove-iam-policy-binding "${EXTERNAL_DNS_GSA}" \
  --role=roles/iam.workloadIdentityUser \
  --member="${WIF_MEMBER}" \
  --project="${HYPERSHIFT_GCP_CI_PROJECT}" || true
gcloud iam service-accounts remove-iam-policy-binding "${EXTERNAL_DNS_GSA}" \
  --role=roles/iam.serviceAccountTokenCreator \
  --member="${WIF_MEMBER}" \
  --project="${HYPERSHIFT_GCP_CI_PROJECT}" || true
set -x

echo "Cleanup complete"
