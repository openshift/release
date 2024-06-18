#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

KV_BASE_NAME="${NAMESPACE}-${UNIQUE_HASH}"
LOCATION="$LEASED_RESOURCE"
RESOURCE_GROUP="$(<"${SHARED_DIR}/resourcegroup")"
az group show --name "$RESOURCE_GROUP"

echo "Creating KeyVault"
KEYVAULT_NAME="${KV_BASE_NAME}-kv"
az keyvault create -n "$KEYVAULT_NAME" -g "$RESOURCE_GROUP" -l "$LOCATION" --enable-purge-protection true --enable-rbac-authorization false

echo "Granting ServicePrincipal permissions to the KeyVault"
az keyvault set-policy -n "$KEYVAULT_NAME" --key-permissions create decrypt encrypt get --spn "$AZURE_AUTH_CLIENT_ID"

echo "Creating Keys within the KeyVault"
KEYVAULT_KEY_NAME="${KV_BASE_NAME}-key"
az keyvault key create --vault-name "$KEYVAULT_NAME" -n "$KEYVAULT_KEY_NAME" --protection software
KEYVAULT_KEY_URL="$(az keyvault key show --vault-name "$KEYVAULT_NAME" --name "$KEYVAULT_KEY_NAME" --query 'key.kid' -o tsv)"

echo "Saving relevant info to \$SHARED_DIR"
# Key URL format: https://<KEYVAULT_NAME>.vault.azure.net/keys/<KEYVAULT_KEY_NAME>/<KEYVAULT_KEY_VERSION>
echo "$KEYVAULT_KEY_URL" > "${SHARED_DIR}/azure_active_key_url"
