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
CUSTOMER_PROJECT_ID="${SHARED_DIR}/customer-project-id"
if [[ -f "${CUSTOMER_PROJECT_ID}" ]]; then
    CUSTOMER_PROJECT_ID="$(<"${SHARED_DIR}/customer-project-id")"
else
    CUSTOMER_PROJECT_ID=""
fi
CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
GCP_REGION="$(<"${SHARED_DIR}/gcp-region")"
INFRA_ID="$(<"${SHARED_DIR}/infra-id")"

set -x

# ============================================================================
# IMPORTANT: Some resources can block or survive project deletion.
# We must explicitly delete these resources before deleting the projects.
# Resources that can block deletion: VPC with active connections, GKE clusters
# ============================================================================

# ----------------------------------------------------------------------------
# Step 1: Delete GKE cluster (blocks project deletion if running)
# ----------------------------------------------------------------------------
echo "Deleting GKE management cluster: ${CLUSTER_NAME}"
gcloud container clusters delete "${CLUSTER_NAME}" \
    --project="${MGMT_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --quiet || true

# Wait for GKE deletion to complete
echo "Waiting for GKE cluster deletion to complete..."
for i in {1..30}; do
    if ! gcloud container clusters describe "${CLUSTER_NAME}" \
        --project="${MGMT_PROJECT_ID}" \
        --region="${GCP_REGION}" 2>/dev/null; then
        echo "GKE cluster deleted successfully"
        break
    fi
    echo "Waiting for GKE cluster deletion... (attempt $i/30)"
    sleep 10
done

# ----------------------------------------------------------------------------
# Step 2: Delete VPC resources in management project
# VPC deletion order: firewall rules -> NAT -> router -> subnets -> VPC
# ----------------------------------------------------------------------------
echo "Cleaning up VPC resources in management project..."

# Delete firewall rules
echo "Deleting firewall rules..."
for fw in $(gcloud compute firewall-rules list --project="${MGMT_PROJECT_ID}" \
    --format="value(name)" 2>/dev/null || true); do
    echo "Deleting firewall rule: ${fw}"
    gcloud compute firewall-rules delete "${fw}" \
        --project="${MGMT_PROJECT_ID}" --quiet || true
done

# Delete Cloud NAT
echo "Deleting Cloud NAT..."
gcloud compute routers nats delete "${INFRA_ID}-nat" \
    --router="${INFRA_ID}-router" \
    --region="${GCP_REGION}" \
    --project="${MGMT_PROJECT_ID}" \
    --quiet || true

# Delete Cloud Router
echo "Deleting Cloud Router..."
gcloud compute routers delete "${INFRA_ID}-router" \
    --region="${GCP_REGION}" \
    --project="${MGMT_PROJECT_ID}" \
    --quiet || true

# Delete subnets (including PSC subnet)
echo "Deleting subnets..."
for subnet in $(gcloud compute networks subnets list --project="${MGMT_PROJECT_ID}" \
    --filter="network~${INFRA_ID}-vpc" --format="value(name,region)" 2>/dev/null || true); do
    subnet_name=$(echo "$subnet" | cut -f1)
    subnet_region=$(echo "$subnet" | cut -f2)
    echo "Deleting subnet: ${subnet_name}"
    gcloud compute networks subnets delete "${subnet_name}" \
        --region="${subnet_region}" \
        --project="${MGMT_PROJECT_ID}" \
        --quiet || true
done

# Delete VPC network
echo "Deleting VPC network..."
gcloud compute networks delete "${INFRA_ID}-vpc" \
    --project="${MGMT_PROJECT_ID}" \
    --quiet || true

# ----------------------------------------------------------------------------
# Step 3: Clean up customer project resources (if customer project was created)
# ----------------------------------------------------------------------------
if [[ -n "${CUSTOMER_PROJECT_ID}" ]]; then
    echo "Cleaning up customer project resources..."

    # Delete firewall rules in customer project
    for fw in $(gcloud compute firewall-rules list --project="${CUSTOMER_PROJECT_ID}" \
        --format="value(name)" 2>/dev/null || true); do
        gcloud compute firewall-rules delete "${fw}" \
            --project="${CUSTOMER_PROJECT_ID}" --quiet || true
    done

    # Delete routers and NATs in customer project
    for router in $(gcloud compute routers list --project="${CUSTOMER_PROJECT_ID}" \
        --format="value(name,region)" 2>/dev/null || true); do
        router_name=$(echo "$router" | cut -f1)
        router_region=$(echo "$router" | cut -f2)
        # Delete NATs first
        for nat in $(gcloud compute routers nats list --router="${router_name}" \
            --region="${router_region}" --project="${CUSTOMER_PROJECT_ID}" \
            --format="value(name)" 2>/dev/null || true); do
            gcloud compute routers nats delete "${nat}" \
                --router="${router_name}" --region="${router_region}" \
                --project="${CUSTOMER_PROJECT_ID}" --quiet || true
        done
        gcloud compute routers delete "${router_name}" \
            --region="${router_region}" \
            --project="${CUSTOMER_PROJECT_ID}" --quiet || true
    done

    # Delete subnets in customer project
    for subnet in $(gcloud compute networks subnets list --project="${CUSTOMER_PROJECT_ID}" \
        --format="value(name,region)" 2>/dev/null || true); do
        subnet_name=$(echo "$subnet" | cut -f1)
        subnet_region=$(echo "$subnet" | cut -f2)
        gcloud compute networks subnets delete "${subnet_name}" \
            --region="${subnet_region}" \
            --project="${CUSTOMER_PROJECT_ID}" --quiet || true
    done

    # Delete VPCs in customer project
    for vpc in $(gcloud compute networks list --project="${CUSTOMER_PROJECT_ID}" \
        --format="value(name)" 2>/dev/null || true); do
        gcloud compute networks delete "${vpc}" \
            --project="${CUSTOMER_PROJECT_ID}" --quiet || true
    done

    # Delete customer project
    echo "Deleting customer project: ${CUSTOMER_PROJECT_ID}"
    gcloud projects delete "${CUSTOMER_PROJECT_ID}" --quiet || true
else
    echo "No customer project to clean up"
fi

# ----------------------------------------------------------------------------
# Step 4: Delete management project (now safe after explicit resource cleanup)
# ----------------------------------------------------------------------------

echo "Deleting management project: ${MGMT_PROJECT_ID}"
gcloud projects delete "${MGMT_PROJECT_ID}" --quiet || true

echo "Cleanup complete"
