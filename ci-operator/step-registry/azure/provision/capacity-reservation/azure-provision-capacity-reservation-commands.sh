#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

REGION="${LEASED_RESOURCE}"
echo "Azure region: ${REGION}"

command -v az
az --version

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

CAPRES_RG="${NAMESPACE}-${UNIQUE_HASH}-capres-rg"
CRG_NAME="${NAMESPACE}-${UNIQUE_HASH}-crg"
CR_NAME="${NAMESPACE}-${UNIQUE_HASH}-cr"

echo "Creating capacity reservation resource group: ${CAPRES_RG}"
az group create -l "${REGION}" -n "${CAPRES_RG}" --output none

echo "Creating capacity reservation group: ${CRG_NAME} in zone ${CAPACITY_RESERVATION_ZONE}"
az capacity reservation group create \
    --resource-group "${CAPRES_RG}" \
    --capacity-reservation-group "${CRG_NAME}" \
    --location "${REGION}" \
    --zones "${CAPACITY_RESERVATION_ZONE}" \
    --output none

echo "Creating capacity reservation: ${CR_NAME} (SKU: ${CAPACITY_RESERVATION_SKU}, count: ${CAPACITY_RESERVATION_COUNT})"
az capacity reservation create \
    --resource-group "${CAPRES_RG}" \
    --capacity-reservation-group "${CRG_NAME}" \
    --capacity-reservation-name "${CR_NAME}" \
    --sku "${CAPACITY_RESERVATION_SKU}" \
    --capacity "${CAPACITY_RESERVATION_COUNT}" \
    --zone "${CAPACITY_RESERVATION_ZONE}" \
    --output none

echo "Capacity reservation created successfully"
az capacity reservation show \
    --resource-group "${CAPRES_RG}" \
    --capacity-reservation-group "${CRG_NAME}" \
    --capacity-reservation-name "${CR_NAME}" \
    --output table

echo "${CAPRES_RG}" > "${SHARED_DIR}/capacity_reservation_rg"
echo "${CRG_NAME}" > "${SHARED_DIR}/capacity_reservation_group_name"
echo "${AZURE_AUTH_SUBSCRIPTION_ID}" > "${SHARED_DIR}/capacity_reservation_subscription_id"
echo "${CAPACITY_RESERVATION_ZONE}" > "${SHARED_DIR}/capacity_reservation_zone"
