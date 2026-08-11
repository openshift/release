#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

capres_rg_file="${SHARED_DIR}/capacity_reservation_rg"
if [[ ! -f "${capres_rg_file}" ]]; then
    echo "No capacity reservation resource group file found, skipping cleanup"
    exit 0
fi

CAPRES_RG=$(< "${capres_rg_file}")

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

if [[ "$(az group exists -n "${CAPRES_RG}")" == "true" ]]; then
    echo "Deleting capacity reservation resource group: ${CAPRES_RG}"
    az group delete -y -n "${CAPRES_RG}"
    echo "Capacity reservation resource group deleted"
else
    echo "Capacity reservation resource group ${CAPRES_RG} does not exist, skipping"
fi
