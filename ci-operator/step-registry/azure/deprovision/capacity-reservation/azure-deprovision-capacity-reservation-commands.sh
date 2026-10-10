#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

capres_rg_file="${SHARED_DIR}/capacity_reservation_rg"
if [[ -s "${capres_rg_file}" ]]; then
    CAPRES_RG=$(< "${capres_rg_file}")
else
    CAPRES_RG="${NAMESPACE}-${UNIQUE_HASH}-capres-rg"
    echo "No capacity reservation resource group file found; using deterministic name: ${CAPRES_RG}"
fi

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

if ! group_exists="$(az group exists -n "${CAPRES_RG}")"; then
    echo "Failed to determine whether capacity reservation resource group exists: ${CAPRES_RG}" >&2
    exit 1
fi

if [[ "${group_exists}" != "true" ]]; then
    echo "Capacity reservation resource group ${CAPRES_RG} does not exist, skipping"
    exit 0
fi

for attempt in {1..3}; do
    echo "Deleting capacity reservation resource group ${CAPRES_RG} (attempt ${attempt}/3)"
    if ! az group delete -y -n "${CAPRES_RG}"; then
        echo "Failed to delete capacity reservation resource group ${CAPRES_RG} on attempt ${attempt}" >&2
    elif ! group_exists="$(az group exists -n "${CAPRES_RG}")"; then
        echo "Failed to verify deletion of capacity reservation resource group ${CAPRES_RG}" >&2
    elif [[ "${group_exists}" == "false" ]]; then
        echo "Capacity reservation resource group deleted"
        exit 0
    else
        echo "Capacity reservation resource group ${CAPRES_RG} still exists after deletion attempt ${attempt}" >&2
    fi

    if [[ "${attempt}" -lt 3 ]]; then
        sleep 30
    fi
done

echo "Failed to delete capacity reservation resource group ${CAPRES_RG}; unused reservations may continue to incur charges" >&2
exit 1
