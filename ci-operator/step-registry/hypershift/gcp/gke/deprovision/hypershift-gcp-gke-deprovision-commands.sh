#!/usr/bin/env bash

set -euo pipefail

# Load GCP credentials from cluster profile
GCP_CREDS_FILE="${CLUSTER_PROFILE_DIR}/credentials.json"
gcloud auth activate-service-account --key-file="${GCP_CREDS_FILE}"

# Load cluster info from SHARED_DIR (written by provision step).
# If SHARED_DIR files are missing (provision was aborted before the Secret was synced),
# reconstruct resource names from env vars since they are deterministic.
if [[ -f "${SHARED_DIR}/control-plane-project-id" ]]; then
    CP_PROJECT_ID="$(<"${SHARED_DIR}/control-plane-project-id")"
    CP_CLUSTER_NAME="$(<"${SHARED_DIR}/control-plane-cluster-name")"
    GCP_REGION="$(<"${SHARED_DIR}/gcp-region")"
else
    # SHARED_DIR is backed by a Kubernetes Secret that is updated after the step exits.
    # If the provision step is aborted (SIGTERM), the Secret update may not complete,
    # leaving SHARED_DIR empty for post steps. Reconstruct from env vars.
    RESOURCE_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
    INFRA_ID="${RESOURCE_NAME_PREFIX}"
    CP_PROJECT_ID="${INFRA_ID:0:14}-control-plane"
    CP_CLUSTER_NAME="${RESOURCE_NAME_PREFIX}-gke"
    GCP_REGION="${GKE_REGION}"
    echo "WARNING: SHARED_DIR files missing - reconstructed resource names from env vars"
    echo "  CP_PROJECT_ID=${CP_PROJECT_ID}"
    echo "  CP_CLUSTER_NAME=${CP_CLUSTER_NAME}"
    echo "  GCP_REGION=${GCP_REGION}"
fi

# hosted-cluster-name may not exist if job was aborted before hosted-cluster-setup ran
if [[ -f "${SHARED_DIR}/hosted-cluster-name" ]]; then
    HC_CLUSTER_NAME="$(<"${SHARED_DIR}/hosted-cluster-name")"
else
    HC_CLUSTER_NAME=""
    echo "WARNING: hosted-cluster-name not found - hosted cluster setup may not have completed"
    echo "Will skip DNS cleanup but still deprovision GKE cluster and projects"
fi

# Hosted Cluster project - read from SHARED_DIR or reconstruct
if [[ -f "${SHARED_DIR}/hosted-cluster-project-id" ]]; then
    HC_PROJECT_ID="$(<"${SHARED_DIR}/hosted-cluster-project-id")"
else
    INFRA_ID="${INFRA_ID:-${NAMESPACE}-${UNIQUE_HASH}}"
    HC_PROJECT_ID="${INFRA_ID:0:14}-hosted-cluster"
    echo "WARNING: Reconstructed HC_PROJECT_ID=${HC_PROJECT_ID}"
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
echo "Deleting GKE Control Plane cluster: ${CP_CLUSTER_NAME}"
gcloud container clusters delete "${CP_CLUSTER_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --async \
    --quiet || true

# Poll for cluster deletion (60 attempts x 10s = 10 minutes max wait)
echo "Waiting for GKE cluster deletion to complete..."
for i in {1..60}; do
    if ! gcloud container clusters describe "${CP_CLUSTER_NAME}" \
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

# Clean up DNS records from the CI zone (DNS records use the hosted cluster name)
DNS_CLEANUP_FAILED=false
if [[ -n "${HC_CLUSTER_NAME}" ]]; then
  echo "Cleaning up DNS records for hosted cluster ${HC_CLUSTER_NAME}..."
  DNS_SUFFIX="in.${HC_CLUSTER_NAME}.${HYPERSHIFT_GCP_CI_DNS_DOMAIN}."
  if ! DNS_RECORDS=$(gcloud dns record-sets list \
    --zone="${HYPERSHIFT_GCP_CI_DNS_ZONE}" \
    --project="${HYPERSHIFT_GCP_CI_PROJECT}" \
    --filter="name ~ ${DNS_SUFFIX}" \
    --format="csv[no-heading](name,type)"); then
    echo "ERROR: Failed to list DNS records - check service account permissions"
    DNS_CLEANUP_FAILED=true
    DNS_RECORDS=""
  fi

  if [[ -n "${DNS_RECORDS}" ]]; then
    while IFS=, read -r name type; do
      [[ -z "${name}" ]] && continue
      echo "Deleting DNS record: ${name} ${type}"
      if ! gcloud dns record-sets delete "${name}" \
        --type="${type}" \
        --zone="${HYPERSHIFT_GCP_CI_DNS_ZONE}" \
        --project="${HYPERSHIFT_GCP_CI_PROJECT}" --quiet; then
        echo "ERROR: Failed to delete DNS record ${name} ${type}"
        DNS_CLEANUP_FAILED=true
      fi
    done <<< "${DNS_RECORDS}"
  else
    echo "No DNS records found matching ${DNS_SUFFIX}"
  fi
else
  echo "Skipping DNS cleanup - hosted cluster name not available"
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

if [[ "${DNS_CLEANUP_FAILED}" == "true" ]]; then
  echo "Cleanup complete but DNS cleanup failed - orphaned DNS records may remain"
  exit 1
fi

echo "Cleanup complete"
