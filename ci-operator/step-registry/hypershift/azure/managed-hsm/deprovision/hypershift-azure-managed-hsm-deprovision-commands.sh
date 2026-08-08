#!/bin/bash

set -euo pipefail

retry() {
  local attempts="$1"
  local delay="$2"
  shift 2

  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then
      return 0
    fi
    if ((attempt == attempts)); then
      echo "Command failed after ${attempts} attempts: $*" >&2
      return 1
    fi
    echo "Attempt ${attempt}/${attempts} failed; retrying in ${delay} seconds"
    sleep "${delay}"
  done
}

deleted_hsm_exists() {
  local count
  count="$(az keyvault list-deleted \
    --resource-type hsm \
    --query "[?name=='${HSM_NAME}'] | length(@)" \
    -o tsv)"
  [[ "${count}" == "1" ]]
}

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

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
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

PURGE_HSM=true
if az keyvault show --hsm-name "${HSM_NAME}" --output none 2>/dev/null; then
  echo "Deleting Managed HSM ${HSM_NAME}"
  az keyvault delete --hsm-name "${HSM_NAME}" --output none
  retry 20 30 deleted_hsm_exists
elif deleted_hsm_exists; then
  echo "Managed HSM ${HSM_NAME} is already soft-deleted"
else
  echo "Managed HSM ${HSM_NAME} was not created; nothing to purge"
  PURGE_HSM=false
fi

if [[ "${PURGE_HSM}" == "true" ]]; then
  echo "Purging Managed HSM ${HSM_NAME}"
  az keyvault purge \
    --hsm-name "${HSM_NAME}" \
    --location "${HYPERSHIFT_AZURE_MANAGED_HSM_LOCATION}" \
    --output none
fi

if az group show --name "${RESOURCE_GROUP}" --output none 2>/dev/null; then
  echo "Deleting resource group ${RESOURCE_GROUP}"
  az group delete --name "${RESOURCE_GROUP}" --yes --no-wait
fi
