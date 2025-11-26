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

# For e2e tests, clusters are created and destroyed within the test run
# We need to extract cluster names from the test artifacts to clean up any orphaned DNS records
echo "Extracting cluster names from e2e test artifacts..."

CLUSTER_NAMES=""

# Find the e2e test log - it could be in various locations depending on CI structure
# Use find to search for it under /logs/artifacts
E2E_LOG=$(find /logs/artifacts -name "build-log.txt" -path "*hypershift-azure-run-e2e*" 2>/dev/null | head -1)

if [[ -n "${E2E_LOG}" && -f "${E2E_LOG}" ]]; then
  echo "Found e2e test log at: ${E2E_LOG}"

  # Extract cluster names from log entries like:
  # "Successfully created hostedcluster e2e-clusters-x5fll/ha-etcd-chaos-sz5qv"
  # The cluster name is the second part after the slash
  CLUSTER_NAMES=$(grep -oE "Successfully created hostedcluster [^/]+/([a-z0-9-]+)" "${E2E_LOG}" 2>/dev/null | \
    sed -n 's/.*\/\([a-z0-9-]*\).*/\1/p' | \
    sort -u || echo "")

  if [[ -n "${CLUSTER_NAMES}" ]]; then
    echo "Found cluster names from test log:"
    echo "${CLUSTER_NAMES}"
  else
    echo "No cluster names found in test log"
  fi
else
  echo "E2E test log not found under /logs/artifacts"
  echo "This may be expected for non-e2e test workflows"
fi

if [[ -z "${CLUSTER_NAMES}" ]]; then
  echo "No cluster names found to clean up DNS records for"
  echo "This is normal if tests cleaned up successfully or for non-e2e workflows"
  exit 0
fi

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

echo "Querying DNS zone for records matching cluster names..."

# Get all DNS records from the zone
ALL_RECORDS_JSON=$(az network dns record-set list \
  --resource-group "${EXTERNAL_DNS_ZONE_RESOURCE_GROUP}" \
  --zone-name "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}" \
  --output json)

# Convert cluster names to a JSON array for jq
CLUSTER_NAMES_JSON=$(echo "${CLUSTER_NAMES}" | jq -R -s 'split("\n") | map(select(length > 0))')

# Find all DNS records that contain any of the cluster names
# This includes:
# - A records: api-{cluster-name}
# - CNAME records: *.apps-{cluster-name}
# - TXT records: a-api-{cluster-name}-external-dns, api-{cluster-name}-external-dns, etc.
RECORDS_TO_DELETE=$(echo "${ALL_RECORDS_JSON}" | jq --argjson cluster_names "${CLUSTER_NAMES_JSON}" '
  [.[] |
   select(.type | endswith("/SOA") | not) |
   select(.type | endswith("/NS") | not) |
   select(
     ($cluster_names | length) > 0 and
     (.name as $name | $cluster_names | any(. as $cluster | $name | contains($cluster)))
   ) |
   {name: .name, type: (.type | split("/")[-1])}
  ]')

RECORD_COUNT=$(echo "${RECORDS_TO_DELETE}" | jq 'length')
echo "Found ${RECORD_COUNT} DNS record(s) to delete"

if [[ "${RECORD_COUNT}" -eq 0 ]]; then
  echo "No DNS records found matching cluster names, cleanup complete"
  exit 0
fi

# Display the records that will be deleted
echo "Records to be deleted:"
echo "${RECORDS_TO_DELETE}" | jq -r '.[] | "\(.type) \(.name)"'

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
    --yes 2>/dev/null; then
    DELETED_COUNT=$((DELETED_COUNT + 1))
    echo "Successfully deleted ${TYPE} record: ${NAME}"
  else
    # Some records might already be deleted or might not exist, don't fail
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo "WARNING: Failed to delete ${TYPE} record: ${NAME} (may already be deleted)"
  fi
done < <(echo "${RECORDS_TO_DELETE}" | jq -c '.[]')

echo "$(date -u --rfc-3339=seconds) - DNS cleanup complete"
echo "Summary: Deleted ${DELETED_COUNT} record(s), Failed ${FAILED_COUNT} record(s)"

if [[ "${FAILED_COUNT}" -gt 0 ]]; then
  echo "Note: Some failures are expected if records were already cleaned up by the test framework"
fi

exit 0
