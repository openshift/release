#!/usr/bin/env bash
# Verify HostedCluster and GCP resources are gone before project cleanup.

set -euo pipefail

REFERENCE_FLOW_FILE="${SHARED_DIR}/gcp-resource-reference-flow"
if [[ ! -f "${REFERENCE_FLOW_FILE}" || "$(<"${REFERENCE_FLOW_FILE}")" != true ]]; then
  echo "GCP resource-reference flow was not exercised; skipping destroy verification"
  exit 0
fi

if [[ ! -f "${SHARED_DIR}/gcp-destroy-complete" ]]; then
  echo "ERROR: GCP resource-reference destroy did not complete successfully"
  exit 1
fi

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster-name")"
if GET_OUTPUT="$(oc get hostedcluster "${CLUSTER_NAME}" -n clusters --request-timeout=10s 2>&1)"; then
  echo "ERROR: HostedCluster/${CLUSTER_NAME} still exists after destroy completed"
  exit 1
elif [[ "${GET_OUTPUT}" != *"(NotFound)"* && "${GET_OUTPUT}" != *"not found"* ]]; then
  echo "ERROR: Could not verify HostedCluster deletion"
  exit 1
fi

HC_PROJECT_ID="$(<"${SHARED_DIR}/hosted-cluster-project-id")"
GCP_REGION="$(<"${SHARED_DIR}/gcp-region")"
VPC_NAME="$(<"${SHARED_DIR}/hc-vpc-name")"
SUBNET_NAME="$(<"${SHARED_DIR}/hc-subnet-name")"
ROUTER_NAME="$(<"${SHARED_DIR}/hc-router-name")"
FIREWALL_RULE_NAME="$(<"${SHARED_DIR}/hc-firewall-rule-name")"
gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json"

# Fail if listing fails or an exact resource name remains.
assert_resource_absent() {
  local description="$1" resource_name="$2"
  shift 2
  local remaining_resources
  if ! remaining_resources="$("$@" --project="${HC_PROJECT_ID}" --format='value(name)')"; then
    echo "ERROR: Failed to list GCP ${description} resources"
    return 1
  fi
  if grep -Fxq "${resource_name}" <<< "${remaining_resources}"; then
    echo "ERROR: GCP ${description} ${resource_name} still exists"
    return 1
  fi
  echo "Verified GCP ${description} ${resource_name} was deleted"
}

assert_resource_absent "VPC" "${VPC_NAME}" gcloud compute networks list
assert_resource_absent "subnet" "${SUBNET_NAME}" gcloud compute networks subnets list --regions="${GCP_REGION}"
assert_resource_absent "Cloud Router" "${ROUTER_NAME}" gcloud compute routers list --regions="${GCP_REGION}"
assert_resource_absent "firewall rule" "${FIREWALL_RULE_NAME}" gcloud compute firewall-rules list
# Cloud NAT is part of its router; the WIF provider is part of its pool.

POOL_ID="$(<"${SHARED_DIR}/wif-pool-id")"
POOL_NAMES="$(gcloud iam workload-identity-pools list --project="${HC_PROJECT_ID}" --location=global --format='value(name)')"
if grep -Fq "/workloadIdentityPools/${POOL_ID}" <<< "${POOL_NAMES}"; then
  echo "ERROR: Workload Identity Pool ${POOL_ID} still exists"
  exit 1
fi
echo "Verified Workload Identity Pool ${POOL_ID} was deleted"

SERVICE_ACCOUNT_EMAILS="$(gcloud iam service-accounts list --project="${HC_PROJECT_ID}" --format='value(email)')"
for account in controlplane nodepool cloudcontroller storage imageregistry network; do
  service_account="$(<"${SHARED_DIR}/${account}-sa")"
  if grep -Fxq "${service_account}" <<< "${SERVICE_ACCOUNT_EMAILS}"; then
    echo "ERROR: GCP service account ${service_account} still exists"
    exit 1
  fi
  echo "Verified GCP service account ${service_account} was deleted"
done

echo "GCP resource-reference destroy completed and all tracked resources were deleted"
