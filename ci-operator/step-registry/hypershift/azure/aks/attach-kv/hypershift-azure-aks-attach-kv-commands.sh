#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
  AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
fi

AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

AZURE_KEY_VAULT_INFO_LOCATION="/etc/hypershift-aro-azurecreds/keyvault-info.json"
if [[ "${USE_HYPERSHIFT_AZURE_CREDS}" == "true" ]]; then
  AZURE_KEY_VAULT_INFO_LOCATION="/etc/hypershift-ci-jobs-azurecreds/keyvault-info.json"
fi
KV_NAME="$(<"${AZURE_KEY_VAULT_INFO_LOCATION}" jq -r .keyvaultName)"
KV_RG_NAME="$(<"${AZURE_KEY_VAULT_INFO_LOCATION}" jq -r .keyvaultRGName)"

set -x

RESOURCE_GROUP="$(<"${SHARED_DIR}/resourcegroup_aks")"
CLUSTER="$(<"${SHARED_DIR}/cluster-name")"

AZURE_KEY_VAULT_AUTHORIZED_OBJECT_ID=$(az aks show -n $CLUSTER -g $RESOURCE_GROUP | jq .addonProfiles.azureKeyvaultSecretsProvider.identity.objectId -r)

echo "Granting the AKS clusters azureKeyvaultSecretsProvider ServicePrincipal permissions to the KeyVault Resource Group"
az role assignment create \
--assignee-object-id $AZURE_KEY_VAULT_AUTHORIZED_OBJECT_ID \
--role "Key Vault Secrets User" \
--scope "/subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}/resourceGroups/${KV_RG_NAME}" \
--assignee-principal-type ServicePrincipal

echo "Granting ServicePrincipal permissions to the KeyVault"
SP_ID=$(az ad sp show --id "$AZURE_AUTH_CLIENT_ID" --query id -o tsv)
KV_ID=$(az keyvault show --name "$KV_NAME" -g "$KV_RG_NAME" --query id -o tsv)
az role assignment create --assignee "$SP_ID" --scope "$KV_ID" --role "Key Vault Administrator"
