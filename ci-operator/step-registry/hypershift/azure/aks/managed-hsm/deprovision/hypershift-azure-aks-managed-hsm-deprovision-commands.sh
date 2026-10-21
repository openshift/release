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

deleted_hsm_absent() {
  local count
  count="$(az keyvault list-deleted \
    --resource-type hsm \
    --query "[?name=='${HSM_NAME}'] | length(@)" \
    -o tsv)"
  [[ "${count}" == "0" ]]
}

if [[ "${HYPERSHIFT_AZURE_MANAGED_HSM}" != "true" ]]; then
  echo "Managed HSM deprovisioning is disabled"
  exit 0
fi

HSM_NAME_FILE="${SHARED_DIR}/azure_managed_hsm_name"
RESOURCE_GROUP_FILE="${SHARED_DIR}/azure_managed_hsm_resource_group"
LOCATION_FILE="${SHARED_DIR}/azure_managed_hsm_location"
if [[ ! -s "${HSM_NAME_FILE}" || ! -s "${RESOURCE_GROUP_FILE}" || ! -s "${LOCATION_FILE}" ]]; then
  echo "Managed HSM cleanup cannot continue because resource information is missing" >&2
  exit 1
fi

AZURE_AUTH_LOCATION="/etc/hypershift-ci-jobs-azurecreds/credentials.json"
AZURE_AUTH_CLIENT_ID="$(jq -er .clientId "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_CLIENT_SECRET="$(jq -er .clientSecret "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_TENANT_ID="$(jq -er .tenantId "${AZURE_AUTH_LOCATION}")"
AZURE_AUTH_SUBSCRIPTION_ID="$(jq -er .subscriptionId "${AZURE_AUTH_LOCATION}")"
HSM_NAME="$(<"${HSM_NAME_FILE}")"
RESOURCE_GROUP="$(<"${RESOURCE_GROUP_FILE}")"
HSM_LOCATION="$(<"${LOCATION_FILE}")"

az cloud set --name AzureCloud
az login \
  --service-principal \
  --username "${AZURE_AUTH_CLIENT_ID}" \
  --password "${AZURE_AUTH_CLIENT_SECRET}" \
  --tenant "${AZURE_AUTH_TENANT_ID}" \
  --output none
az account set --subscription "${AZURE_AUTH_SUBSCRIPTION_ID}"

ACTIVE_HSM_COUNT="$(az keyvault list \
  --resource-type hsm \
  --query "[?name=='${HSM_NAME}'] | length(@)" \
  -o tsv)"
DELETED_HSM_COUNT="$(az keyvault list-deleted \
  --resource-type hsm \
  --query "[?name=='${HSM_NAME}'] | length(@)" \
  -o tsv)"

if [[ "${ACTIVE_HSM_COUNT}" == "1" ]]; then
  echo "Deleting Managed HSM ${HSM_NAME}"
  az keyvault delete --hsm-name "${HSM_NAME}" --output none
  retry 20 30 deleted_hsm_exists
elif [[ "${ACTIVE_HSM_COUNT}" != "0" ]]; then
  echo "Unexpected active Managed HSM count for ${HSM_NAME}: ${ACTIVE_HSM_COUNT}" >&2
  exit 1
elif [[ "${DELETED_HSM_COUNT}" == "1" ]]; then
  echo "Managed HSM ${HSM_NAME} is already soft-deleted"
elif [[ "${DELETED_HSM_COUNT}" != "0" ]]; then
  echo "Unexpected deleted Managed HSM count for ${HSM_NAME}: ${DELETED_HSM_COUNT}" >&2
  exit 1
else
  echo "Managed HSM ${HSM_NAME} was not created; nothing to purge"
fi

if [[ "${ACTIVE_HSM_COUNT}" == "1" || "${DELETED_HSM_COUNT}" == "1" ]]; then
  echo "Purging Managed HSM ${HSM_NAME}"
  az keyvault purge \
    --hsm-name "${HSM_NAME}" \
    --location "${HSM_LOCATION}" \
    --output none
  retry 20 15 deleted_hsm_absent
fi

RESOURCE_GROUP_EXISTS="$(az group exists --name "${RESOURCE_GROUP}")"
if [[ "${RESOURCE_GROUP_EXISTS}" == "true" ]]; then
  echo "Deleting resource group ${RESOURCE_GROUP}"
  az group delete --name "${RESOURCE_GROUP}" --yes
elif [[ "${RESOURCE_GROUP_EXISTS}" != "false" ]]; then
  echo "Unexpected resource group existence result for ${RESOURCE_GROUP}: ${RESOURCE_GROUP_EXISTS}" >&2
  exit 1
fi
