#!/usr/bin/env bash

set -euo pipefail

# Load GCP credentials from cluster profile
GCP_CREDS_FILE="${CLUSTER_PROFILE_DIR}/credentials.json"
gcloud auth activate-service-account --key-file="${GCP_CREDS_FILE}"

# Check if provision completed - if not, nothing to clean up
if [[ ! -f "${SHARED_DIR}/mgmt-project-id" ]]; then
    echo "No mgmt-project-id file found - provision may not have completed"
    echo "Nothing to deprovision, exiting successfully"
    exit 0
fi

# Load cluster info from provision step
MGMT_PROJECT_ID="$(<"${SHARED_DIR}/mgmt-project-id")"
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
GCP_REGION="$(<"${SHARED_DIR}/gcp-region")"

# Customer project file path (may not exist if provision failed early)
CUSTOMER_PROJECT_FILE="${SHARED_DIR}/customer-project-id"
if [[ -f "${CUSTOMER_PROJECT_FILE}" ]]; then
    CUSTOMER_PROJECT_ID="$(<"${CUSTOMER_PROJECT_FILE}")"
else
    CUSTOMER_PROJECT_ID=""
fi

set -x

# ============================================================================
# Cleanup Strategy:
# 1. Delete customer project first (removes cross-project PSC references)
# 2. Delete GKE cluster (has finalizers, must complete before project deletion)
# 3. Delete management project (handles remaining VPCs, firewall rules)
#
# We use --async + polling for GKE deletion for explicit control over
# completion status and better timeout handling.
# ============================================================================

# ----------------------------------------------------------------------------
# Step 1: Delete customer project (if it exists)
# Delete first to remove any cross-project dependencies (PSC endpoints, etc.)
# ----------------------------------------------------------------------------
if [[ -n "${CUSTOMER_PROJECT_ID}" ]]; then
    echo "Deleting customer project: ${CUSTOMER_PROJECT_ID}"
    gcloud projects delete "${CUSTOMER_PROJECT_ID}" --quiet || true
else
    echo "No customer project to clean up"
fi

# ----------------------------------------------------------------------------
# Step 2: Delete GKE cluster
# Using --async + polling for explicit control over completion
# ----------------------------------------------------------------------------
echo "Deleting GKE management cluster: ${CLUSTER_NAME}"
gcloud container clusters delete "${CLUSTER_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --async \
    --quiet || true

# Poll for cluster deletion (60 attempts x 10s = 10 minutes max wait)
echo "Waiting for GKE cluster deletion to complete..."
for i in {1..60}; do
    if ! gcloud container clusters describe "${CLUSTER_NAME}" \
        --project="${MGMT_PROJECT_ID}" \
        --region="${GCP_REGION}" 2>/dev/null; then
        echo "GKE cluster deleted successfully"
        break
    fi
    echo "Waiting for GKE cluster deletion... (attempt $i/60)"
    sleep 10
done

# ----------------------------------------------------------------------------
# Step 3: Delete management project
# ----------------------------------------------------------------------------
echo "Deleting management project: ${MGMT_PROJECT_ID}"
gcloud projects delete "${MGMT_PROJECT_ID}" --quiet || true

echo "Cleanup complete"
