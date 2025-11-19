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

# Try to get external-dns owner ID from the management cluster
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
elif [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

OWNER_ID=""
if [[ -n "${KUBECONFIG:-}" ]]; then
  echo "Querying management cluster for external-dns owner ID..."
  echo "DEBUG: KUBECONFIG=${KUBECONFIG}"

  # Check if the cluster is accessible
  if ! kubectl get ns hypershift &>/dev/null; then
    echo "DEBUG: Cannot access hypershift namespace on management cluster"
  else
    echo "DEBUG: Successfully accessed hypershift namespace"

    # Get the owner ID from the external-dns deployment
    # This is the unique identifier that external-dns uses to tag all DNS records it creates
    OWNER_ID=$(kubectl get deployment -n hypershift external-dns -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="EXTERNAL_DNS_TXT_OWNER_ID")].value}' 2>/dev/null || echo "")

    if [[ -n "${OWNER_ID}" ]]; then
      echo "Found external-dns owner ID from deployment: ${OWNER_ID}"
    else
      echo "DEBUG: Could not find EXTERNAL_DNS_TXT_OWNER_ID env var in deployment"
      echo "DEBUG: Checking all env vars in external-dns deployment..."
      kubectl get deployment -n hypershift external-dns -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null | tr ' ' '\n' | grep -i owner || echo "DEBUG: No owner-related env vars found"
    fi
  fi
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

# If we don't have an owner ID from the cluster, try to extract it from existing TXT records
if [[ -z "${OWNER_ID}" ]]; then
  echo "Attempting to extract owner ID from existing TXT records in the DNS zone..."

  # Get a sample TXT record to extract the owner ID
  echo "DEBUG: Querying TXT records from zone ${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}..."
  SAMPLE_TXT=$(az network dns record-set txt list \
    --resource-group "${EXTERNAL_DNS_ZONE_RESOURCE_GROUP}" \
    --zone-name "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}" \
    --output json | \
    jq -r '[.[] | select(.name | endswith("-external-dns"))] | .[0].txtRecords[0].value[0]' 2>/dev/null || echo "")

  echo "DEBUG: Sample TXT record value: ${SAMPLE_TXT}"

  if [[ -n "${SAMPLE_TXT}" ]]; then
    # Extract owner ID from the TXT record value which looks like:
    # "heritage=external-dns,external-dns/owner=a0ad2bd1-c681-4f8a-9147-d4a4d8752579,external-dns/resource=..."
    # Use sed for portability (grep -P may not be available)
    OWNER_ID=$(echo "${SAMPLE_TXT}" | sed -n 's/.*external-dns\/owner=\([a-f0-9-]*\).*/\1/p' || echo "")

    if [[ -n "${OWNER_ID}" ]]; then
      echo "Extracted owner ID from DNS records: ${OWNER_ID}"
    else
      echo "DEBUG: Failed to extract owner ID from sample TXT: ${SAMPLE_TXT}"
    fi
  else
    echo "DEBUG: No TXT records found in DNS zone with -external-dns suffix"
  fi
fi

if [[ -z "${OWNER_ID}" ]]; then
  echo "ERROR: Could not determine external-dns owner ID"
  echo "Cannot safely identify which DNS records to clean up"
  exit 0
fi

echo "Querying DNS zone for all records owned by external-dns instance: ${OWNER_ID}"

# Get all TXT records that contain this owner ID
# These TXT records are ownership markers created by external-dns
OWNERSHIP_RECORDS=$(az network dns record-set txt list \
  --resource-group "${EXTERNAL_DNS_ZONE_RESOURCE_GROUP}" \
  --zone-name "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}" \
  --output json | \
  jq --arg owner_id "${OWNER_ID}" '
    [.[] |
     select(.name | endswith("-external-dns")) |
     select(.txtRecords[0].value[0] | contains($owner_id)) |
     .name
    ]')

OWNERSHIP_COUNT=$(echo "${OWNERSHIP_RECORDS}" | jq 'length')
echo "Found ${OWNERSHIP_COUNT} TXT ownership record(s) with owner ID ${OWNER_ID}"

if [[ "${OWNERSHIP_COUNT}" -eq 0 ]]; then
  echo "No DNS records found for this external-dns instance, cleanup complete"
  exit 0
fi

echo "Ownership records to be deleted:"
echo "${OWNERSHIP_RECORDS}" | jq -r '.[]'

# For each ownership TXT record, we need to:
# 1. Delete the TXT ownership records themselves (e.g., "a-api-cluster-xyz-external-dns" and "api-cluster-xyz-external-dns")
# 2. Delete the actual DNS record they protect (e.g., "api-cluster-xyz")

# Extract the base record names from ownership records
# Ownership records follow patterns:
# - "a-{record-name}-external-dns" (CNAME prefix for A records)
# - "{record-name}-external-dns" (direct TXT record)
# - "cname-{record-name}-external-dns" (for CNAME records)

# Build a list of all records to delete (both TXT and actual records)
ALL_RECORDS_JSON=$(az network dns record-set list \
  --resource-group "${EXTERNAL_DNS_ZONE_RESOURCE_GROUP}" \
  --zone-name "${HYPERSHIFT_EXTERNAL_DNS_DOMAIN}" \
  --output json)

# Extract all record names that need to be deleted
RECORDS_TO_DELETE=$(echo "${OWNERSHIP_RECORDS}" | jq -r --argjson all_records "${ALL_RECORDS_JSON}" '
  # For each ownership record, extract the base name and find matching records
  [.[] as $owner_rec |
    # Remove "-external-dns" suffix
    ($owner_rec | sub("-external-dns$"; "")) as $base_with_prefix |
    # Remove "a-" or "cname-" prefix if present
    ($base_with_prefix | sub("^(a|cname)-"; "")) as $base_name |

    # Find all records (TXT and actual) that match this base name
    $all_records[] |
    select(
      (.name == $owner_rec) or                    # The ownership TXT record itself
      (.name == $base_with_prefix) or             # The prefixed version
      (.name == $base_name)                        # The actual DNS record
    ) |
    select(.type | endswith("/SOA") | not) |      # Never delete SOA records
    select(.type | endswith("/NS") | not) |       # Never delete NS records
    {name: .name, type: (.type | split("/")[-1])}
  ] | unique_by(.name + .type)')

RECORD_COUNT=$(echo "${RECORDS_TO_DELETE}" | jq 'length')
echo "Found ${RECORD_COUNT} total DNS record(s) to delete (including TXT ownership records)"

if [[ "${RECORD_COUNT}" -eq 0 ]]; then
  echo "No DNS records found to delete, cleanup complete"
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
  echo "Note: Some failures are expected if external-dns already deleted some records"
fi

exit 0
