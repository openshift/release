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
# Cleanup Strategy:
# 1. Delete Hosted Cluster project first (removes cross-project PSC references)
# 2. Delete GKE cluster (has finalizers, must complete before project deletion)
# 3. Delete Control Plane project (handles remaining VPCs, firewall rules)
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

echo "Cleanup complete"
