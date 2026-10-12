#!/usr/bin/env bash

set -euo pipefail

function poll() {
    local command="$1"
    local max_retries="${2:-5}"
    local polling_interval="${3:-60}"
    local attempt=1

    while ! eval "$command"; do
        echo "Attempt $attempt failed. Retrying in $polling_interval seconds..."
        if (( attempt >= max_retries )); then
            echo "Command failed after $max_retries attempts. Exiting." >&2
            return 1
        fi
        (( attempt++ ))
        sleep "$polling_interval"
    done
}

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
PRESERVED_KV_INFO_LOCATION="/etc/hypershift-aro-azurecreds/keyvault-info.json"
KMS_SECRET_NAME_FILE="/etc/hypershift-aro-azurecreds/kms-credentials-secret-name"
KMS_SECRET_NAME=$(cat "$KMS_SECRET_NAME_FILE")
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
    AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
    PRESERVED_KV_INFO_LOCATION="/etc/hypershift-ci-jobs-azurecreds/keyvault-info.json"
    AKS_KMS_INFO_LOCATION="/etc/hypershift-ci-jobs-azurecreds/aks-kms-info.json"
    KMS_SECRET_NAME=$(jq -r '."aks-kms-credentials-secret"' < "$AKS_KMS_INFO_LOCATION")
fi
PRESERVED_KV_NAME="$(<"${PRESERVED_KV_INFO_LOCATION}" jq -r .keyvaultName)"

AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

set -x

KV_BASE_NAME="${NAMESPACE}-${UNIQUE_HASH}"
LOCATION=${HYPERSHIFT_AZURE_LOCATION:-${LEASED_RESOURCE}}

if [[ $AZURE_KEYVAULT_USE_AKS_RG == "true" ]]; then
    RESOURCE_GROUP="$(<"${SHARED_DIR}/resourcegroup_aks")"
else
    RESOURCE_GROUP="$(<"${SHARED_DIR}/resourcegroup")"
fi
az group show --name "$RESOURCE_GROUP"

echo "Creating KeyVault"
KEYVAULT_NAME="${KV_BASE_NAME}-kv"
# Set soft delete data retention to 7 days (minimum) instead of the default 90 days to reduce the risk of Key Vault name collisions
az keyvault create -n "$KEYVAULT_NAME" -g "$RESOURCE_GROUP" -l "$LOCATION" --enable-purge-protection --enable-rbac-authorization --retention-days 7

echo "Granting ServicePrincipal permissions to the KeyVault"
SP_ID=$(az ad sp show --id "$AZURE_AUTH_CLIENT_ID" --query id -o tsv)
KV_ID=$(az keyvault show --name "$KEYVAULT_NAME" -g "$RESOURCE_GROUP" --query id -o tsv)
az role assignment create --assignee "$SP_ID" --scope "$KV_ID" --role "Key Vault Administrator"

echo "Creating Keys within the KeyVault"
KEYVAULT_KEY_NAME="${KV_BASE_NAME}-key"
poll "az keyvault key create --vault-name $KEYVAULT_NAME -n $KEYVAULT_KEY_NAME --protection software"
poll "KEYVAULT_KEY_URL=\$(az keyvault key show --vault-name \"$KEYVAULT_NAME\" --name \"$KEYVAULT_KEY_NAME\" --query 'key.kid' -o tsv)"

# Grant Key Vault Crypto User role for KMS encryption operations
echo "Reading KMS credentials from preserved Key Vault: $PRESERVED_KV_NAME"
KMS_SECRET_JSON=$(az keyvault secret show --vault-name "$PRESERVED_KV_NAME" --name "$KMS_SECRET_NAME" --query value -o tsv 2>/dev/null || true)

# Extract ClientId from the secret
KMS_CLIENT_ID=$(echo "$KMS_SECRET_JSON" | jq -r .client_id)

# Query Azure AD for the service principal's ObjectId using the ClientId
KMS_OBJECT_ID=$(az ad sp show --id "$KMS_CLIENT_ID" --query id -o tsv)
echo "Found KMS Service Principal Object ID: $KMS_OBJECT_ID"

# Grant Key Vault Crypto User role to KMS service principal on the TEST vault
if [ -z "$(az role assignment list --assignee $KMS_OBJECT_ID --role "Key Vault Crypto User" --scope $KV_ID -o tsv)" ]; then
    echo "Creating Key Vault Crypto User role assignment on vault: $KEYVAULT_NAME"
    az role assignment create \
        --assignee-object-id $KMS_OBJECT_ID \
        --role "Key Vault Crypto User" \
        --scope $KV_ID \
        --assignee-principal-type ServicePrincipal
    echo "Key Vault Crypto User role granted successfully."
else
    echo "KMS service principal already has Key Vault Crypto User role on this vault. Skipping."
fi

echo "Saving relevant info to \$SHARED_DIR"
# Key URL format: https://<KEYVAULT_NAME>.vault.azure.net/keys/<KEYVAULT_KEY_NAME>/<KEYVAULT_KEY_VERSION>
echo "$KEYVAULT_KEY_URL" > "${SHARED_DIR}/azure_active_key_url"
echo "$KEYVAULT_NAME" > "${SHARED_DIR}/azure_keyvault_name"
echo "$AZURE_AUTH_TENANT_ID" > "${SHARED_DIR}/azure_keyvault_tenant_id"
