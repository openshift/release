#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_LOCATION="$LEASED_RESOURCE"

RESOURCE_NAME_PREFIX="$(echo -n "$PROW_JOB_ID" | sha256sum | cut -c -15)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

echo "Creating Storage Account in its own RG"
SA_RESOURCE_GROUP="${RESOURCE_NAME_PREFIX}-rg"
az group create --name "$SA_RESOURCE_GROUP" --location "$AZURE_LOCATION"
echo "$SA_RESOURCE_GROUP" > "${SHARED_DIR}/resourcegroup_sa"

# Storage account name must be between 3 and 24 characters in length and use numbers and lower-case letters only.
SA_NAME="${RESOURCE_NAME_PREFIX}sa"
CREATE_SA_CMD=(
    az storage account create
    --location "$AZURE_LOCATION"
    --name "$SA_NAME"
    --resource-group "$SA_RESOURCE_GROUP"
)
if [[ -n $AZURE_STORAGE_ACCOUNT_KIND ]]; then
    CREATE_SA_CMD+=(--kind "$AZURE_STORAGE_ACCOUNT_KIND")
fi
if [[ -n $AZURE_STORAGE_ACCOUNT_SKU ]]; then
    CREATE_SA_CMD+=(--sku "$AZURE_STORAGE_ACCOUNT_SKU")
fi
eval "${CREATE_SA_CMD[*]}"

SA_BLOB_ENDPOINT="$(az storage account show --name "$SA_NAME" --resource-group "$SA_RESOURCE_GROUP" --query "primaryEndpoints.blob" --output tsv)"
echo "$SA_BLOB_ENDPOINT" > "${SHARED_DIR}/azure_storage_account_blob_endpoint"
