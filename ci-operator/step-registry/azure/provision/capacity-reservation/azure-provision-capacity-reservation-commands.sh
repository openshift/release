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
CONTROL_PLANE_CR_NAME="${NAMESPACE}-${UNIQUE_HASH}-master-cr"
COMPUTE_CR_NAME="${NAMESPACE}-${UNIQUE_HASH}-worker-cr"

echo "${CAPRES_RG}" > "${SHARED_DIR}/capacity_reservation_rg"

echo "Creating capacity reservation resource group: ${CAPRES_RG}"
az group create -l "${REGION}" -n "${CAPRES_RG}" --output none

echo "Creating capacity reservation group: ${CRG_NAME} in zone ${CAPACITY_RESERVATION_ZONE}"
az capacity reservation group create \
    --resource-group "${CAPRES_RG}" \
    --capacity-reservation-group "${CRG_NAME}" \
    --location "${REGION}" \
    --zones "${CAPACITY_RESERVATION_ZONE}" \
    --output none

create_capacity_reservation() {
    local name="$1"
    local sku="$2"
    local count="$3"

    echo "Creating capacity reservation: ${name} (SKU: ${sku}, count: ${count})"
    az capacity reservation create \
        --resource-group "${CAPRES_RG}" \
        --capacity-reservation-group "${CRG_NAME}" \
        --capacity-reservation-name "${name}" \
        --sku "${sku}" \
        --capacity "${count}" \
        --zone "${CAPACITY_RESERVATION_ZONE}" \
        --output none
}

create_capacity_reservation \
    "${CONTROL_PLANE_CR_NAME}" \
    "${CONTROL_PLANE_CAPACITY_RESERVATION_SKU}" \
    "${CONTROL_PLANE_CAPACITY_RESERVATION_COUNT}"
create_capacity_reservation \
    "${COMPUTE_CR_NAME}" \
    "${COMPUTE_CAPACITY_RESERVATION_SKU}" \
    "${COMPUTE_CAPACITY_RESERVATION_COUNT}"

echo "Capacity reservations created successfully"
az capacity reservation list \
    --resource-group "${CAPRES_RG}" \
    --capacity-reservation-group "${CRG_NAME}" \
    --output table

echo "${CRG_NAME}" > "${SHARED_DIR}/capacity_reservation_group_name"
echo "${CONTROL_PLANE_CR_NAME}" > "${SHARED_DIR}/capacity_reservation_control_plane_name"
echo "${COMPUTE_CR_NAME}" > "${SHARED_DIR}/capacity_reservation_compute_name"
echo "${AZURE_AUTH_SUBSCRIPTION_ID}" > "${SHARED_DIR}/capacity_reservation_subscription_id"
echo "${CAPACITY_RESERVATION_ZONE}" > "${SHARED_DIR}/capacity_reservation_zone"
