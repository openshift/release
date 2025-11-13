#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Starting external-dns cleanup"

# Check if external DNS domain is configured
if [[ -z "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN:-}" ]]; then
  echo "HYPERSHIFT_EXTERNAL_DNS_DOMAIN is not set, skipping DNS cleanup"
  exit 0
fi

# Try to get infraIDs from HostedClusters on the management cluster first
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
elif [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

INFRA_IDS=""
if [[ -n "${KUBECONFIG:-}" ]]; then
  echo "Querying management cluster for HostedClusters..."
  INFRA_IDS=$(kubectl get hostedclusters --all-namespaces -o jsonpath='{range .items[*]}{.spec.infraID}{"\n"}{end}' 2>/dev/null || echo "")
fi

# For e2e tests, HostedClusters are destroyed as part of test teardown before cleanup runs
# Fall back to extracting infraIDs from the test output logs
if [[ -z "${INFRA_IDS}" ]]; then
  echo "No HostedClusters found on management cluster"
  echo "Attempting to extract infraIDs from test artifacts..."

  # Look for the hypershift-azure-run-e2e test logs
  E2E_LOG="${ARTIFACT_DIR}/../hypershift-azure-run-e2e/build-log.txt"
  if [[ -f "${E2E_LOG}" ]]; then
    # Extract infraIDs from log entries like "Successfully created hostedcluster e2e-clusters-xxx/create-cluster-abc123"
    # HyperShift infraIDs follow pattern: test-name-xxxxx (lowercase alphanumeric + hyphens)
    INFRA_IDS=$(grep -oE "(create-cluster|autoscaling|azure-scheduler|cilium-connectivity|control-plane-upgrade|konnectivity|node-pool|private|etcd)-[a-z0-9]{5,6}" "${E2E_LOG}" 2>/dev/null | sort -u || echo "")
  fi
fi

if [[ -z "${INFRA_IDS}" ]]; then
  echo "No infraIDs found to clean up"
  exit 0
fi

echo "Found infraIDs to clean up:"
echo "${INFRA_IDS}"

# Set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
  AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi

AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# Log in with az
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

echo "Logged into Azure successfully"

# Check if the DNS zone exists
if ! az network dns zone show --resource-group "${EXTERNAL_DNS_ZONE_RESOURCE_GROUP}" --name "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}" &>/dev/null; then
  echo "DNS zone ${HYPERSHIFT_EXTERNAL_DNS_DOMAIN} not found in resource group ${EXTERNAL_DNS_ZONE_RESOURCE_GROUP}, nothing to clean up"
  exit 0
fi

echo "Listing DNS records matching infraIDs in zone ${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}"

# List all DNS records that match any of the infraIDs
# External-DNS creates records with patterns like:
# - api-{infraID}.{zone}
# - *.apps-{infraID}.{zone}
# - a-api-{infraID}-external-dns (TXT ownership records)
# - a-ignition-{infraID}-external-dns (TXT ownership records)
# We search for records containing any of the infraIDs from HostedClusters created in this test run

# Convert infraIDs to a JSON array for jq
INFRA_IDS_JSON=$(echo "${INFRA_IDS}" | jq -R -s 'split("\n") | map(select(length > 0))')

RECORDS_JSON=$(az network dns record-set list \
  --resource-group "${EXTERNAL_DNS_ZONE_RESOURCE_GROUP}" \
  --zone-name "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}" \
  --output json | \
  jq --argjson infra_ids "${INFRA_IDS_JSON}" '
    [.[] |
     select(.type | endswith("/SOA") | not) |
     select(.type | endswith("/NS") | not) |
     select(
       ($infra_ids | length) > 0 and
       (.name as $name | $infra_ids | any(. as $id | $name | contains($id)))
     ) |
     {name: .name, type: (.type | split("/")[-1])}
    ]')

RECORD_COUNT=$(echo "${RECORDS_JSON}" | jq 'length')
echo "Found ${RECORD_COUNT} DNS record(s) to delete"

if [[ "${RECORD_COUNT}" -eq 0 ]]; then
  echo "No DNS records found matching infraIDs, cleanup complete"
  exit 0
fi

# Display the records that will be deleted
echo "Records to be deleted:"
echo "${RECORDS_JSON}" | jq -r '.[] | "\(.type) \(.name)"'

# Delete each record
DELETED_COUNT=0
FAILED_COUNT=0

while read -r record; do
  NAME=$(echo "$record" | jq -r '.name')
  TYPE=$(echo "$record" | jq -r '.type' | tr '[:upper:]' '[:lower:]')

  echo "Deleting ${TYPE} record: ${NAME}"

  if az network dns record-set "${TYPE}" delete \
    --resource-group "${EXTERNAL_DNS_ZONE_RESOURCE_GROUP}" \
    --zone-name "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}" \
    --name "${NAME}" \
    --yes; then
    DELETED_COUNT=$((DELETED_COUNT + 1))
    echo "Successfully deleted ${TYPE} record: ${NAME}"
  else
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo "WARNING: Failed to delete ${TYPE} record: ${NAME}"
  fi
done < <(echo "${RECORDS_JSON}" | jq -c '.[]')

echo "$(date -u --rfc-3339=seconds) - DNS cleanup complete"
echo "Summary: Deleted ${DELETED_COUNT} record(s), Failed ${FAILED_COUNT} record(s)"

if [[ "${FAILED_COUNT}" -gt 0 ]]; then
  echo "WARNING: Some DNS records failed to delete, but continuing with deprovision"
fi

exit 0
