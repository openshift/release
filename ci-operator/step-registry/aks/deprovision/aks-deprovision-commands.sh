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

AZURE_KEY_VAULT_INFO_LOCATION="/etc/hypershift-ci-jobs-azurecreds/keyvault-info.json"
KV_RG_NAME="$(<"${AZURE_KEY_VAULT_INFO_LOCATION}" jq -r .keyvaultRGName)"

CLUSTER="$(<"${SHARED_DIR}/cluster-name")"
RESOURCEGROUP="$(<"${SHARED_DIR}/resourcegroup_aks")"
AKS_KV_SECRETS_PROVIDER_OBJECT_ID="$(<"${SHARED_DIR}/kv-object-id")"

az --version
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

# Delete the role assignment before deleting the cluster
ROLE_ASSIGNMENT_ID=$(az role assignment list \
  --assignee "${AKS_KV_SECRETS_PROVIDER_OBJECT_ID}" \
  --role "Key Vault Secrets User" \
  --scope /subscriptions/"${AZURE_AUTH_SUBSCRIPTION_ID}"/resourceGroups/"${RESOURCEGROUP}" \
  --output tsv \
  --query "[].id")

if [ -n "$ROLE_ASSIGNMENT_ID" ]; then
  az role assignment delete --ids "$ROLE_ASSIGNMENT_ID"
  echo "Role assignment deleted for the RESOURCEGROUP."
else
  echo "Role assignment not found for the RESOURCEGROUP."
fi

# Delete the role assignment on the KV_RG_NAME before deleting the AKS cluster
KV_ROLE_ASSIGNMENT_ID=$(az role assignment list \
  --assignee "${AKS_KV_SECRETS_PROVIDER_OBJECT_ID}" \
  --role "Key Vault Secrets User" \
  --scope /subscriptions/"${AZURE_AUTH_SUBSCRIPTION_ID}"/resourceGroups/"${KV_RG_NAME}" \
  --output tsv \
  --query "[].id")

if [ -n "$KV_ROLE_ASSIGNMENT_ID" ]; then
  az role assignment delete --ids "$KV_ROLE_ASSIGNMENT_ID"
  echo "Role assignment deleted for the KV_RG_NAME."
else
  echo "Role assignment not found for the KV_RG_NAME."
fi

# Delete the AKS management cluster
az aks delete --name "$CLUSTER" --resource-group "$RESOURCEGROUP" --yes
