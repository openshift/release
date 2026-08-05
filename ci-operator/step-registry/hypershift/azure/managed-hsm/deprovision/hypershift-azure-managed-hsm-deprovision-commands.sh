#!/bin/bash

set -euo pipefail

if [[ "${HYPERSHIFT_AZURE_MANAGED_HSM}" != "true" ]]; then
  echo "Managed HSM deprovisioning is disabled"
  exit 0
fi

HSM_NAME_FILE="${SHARED_DIR}/azure_managed_hsm_name"
RESOURCE_GROUP_FILE="${SHARED_DIR}/azure_managed_hsm_resource_group"
if [[ ! -s "${HSM_NAME_FILE}" || ! -s "${RESOURCE_GROUP_FILE}" ]]; then
  echo "Managed HSM resource information was not written; nothing to delete"
  exit 0
fi

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
AZURE_AUTH_CLIENT_ID="$(jq -er .clientId "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_CLIENT_SECRET="$(jq -er .clientSecret "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_TENANT_ID="$(jq -er .tenantId "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_SUBSCRIPTION_ID="$(jq -er .subscriptionId "${AZURE_AUTH_LOCATION}")"
HSM_NAME="$(<"${HSM_NAME_FILE}")"
RESOURCE_GROUP="$(<"${RESOURCE_GROUP_FILE}")"

az cloud set --name AzureCloud
az login \
  --service-principal \
  --username "${AZURE_AUTH_CLIENT_ID}" \
  --password "${AZURE_AUTH_CLIENT_SECRET}" \
  --tenant "${AZURE_AUTH_TENANT_ID}" \
  --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

if az keyvault show --hsm-name "${HSM_NAME}" --output none 2>/dev/null; then
  echo "Deleting Managed HSM ${HSM_NAME}"
  az keyvault delete --hsm-name "${HSM_NAME}" --output none
else
  echo "Managed HSM ${HSM_NAME} does not exist or is already deleted"
fi

if az group show --name "${RESOURCE_GROUP}" --output none 2>/dev/null; then
  echo "Deleting resource group ${RESOURCE_GROUP}"
  az group delete --name "${RESOURCE_GROUP}" --yes --no-wait
fi
