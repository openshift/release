#!/usr/bin/env bash

set -euo pipefail

# az should already be there
command -v az
az --version

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_LOCATION="$LEASED_RESOURCE"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

RESOURCE_NAME_PREFIX="$(echo -n "$PROW_JOB_ID" | sha256sum | cut -c -15)"

set -x

echo "Creating Storage Account in its own RG"
SA_RESOURCE_GROUP="${NAMESPACE}-${UNIQUE_HASH}-sa-rg"
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
echo "$SA_NAME" > "${SHARED_DIR}/azure_storage_account_name"
echo "$SA_BLOB_ENDPOINT" > "${SHARED_DIR}/azure_storage_account_blob_endpoint"
