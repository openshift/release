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
# 1. Delete GKE cluster first (has finalizers, can block project deletion)
# 2. Delete projects (handles remaining resources like VPCs, firewall rules)
#
# We use --async for GKE deletion since project deletion will wait for
# any remaining cleanup. Individual VPC resource cleanup is skipped since
# project deletion handles it automatically.
# ============================================================================

# ----------------------------------------------------------------------------
# Step 1: Delete GKE cluster (must be deleted before project)
# ----------------------------------------------------------------------------
echo "Deleting GKE management cluster: ${CLUSTER_NAME}"
gcloud container clusters delete "${CLUSTER_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --async \
    --quiet || true

# Brief wait for cluster deletion to start before project deletion
echo "Waiting for GKE cluster deletion to initiate..."
sleep 30

# ----------------------------------------------------------------------------
# Step 2: Delete customer project (if it exists)
# ----------------------------------------------------------------------------
if [[ -n "${CUSTOMER_PROJECT_ID}" ]]; then
    echo "Deleting customer project: ${CUSTOMER_PROJECT_ID}"
    gcloud projects delete "${CUSTOMER_PROJECT_ID}" --quiet || true
else
    echo "No customer project to clean up"
fi

# ----------------------------------------------------------------------------
# Step 3: Delete management project
# ----------------------------------------------------------------------------
echo "Deleting management project: ${MGMT_PROJECT_ID}"
gcloud projects delete "${MGMT_PROJECT_ID}" --quiet || true

echo "Cleanup complete"
