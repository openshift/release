#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

cluster_rg=$(yq-go r ${CONFIG} 'platform.azure.resourceGroupName')
vnet_rg=$(yq-go r ${CONFIG} 'platform.azure.networkResourceGroupName')

if [[ -z "${cluster_rg}" ]] && [[ -z "${vnet_rg}" ]]; then
    echo "This step used to grant proper permissions on scope of cluster rg or vnet rg, but both rg are empty, skip..."
    exit 0
fi

# az should already be there
command -v az

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

cluster_sp_id=${AZURE_AUTH_CLIENT_ID}
if [[ -f "${SHARED_DIR}/azure_minimal_permission" ]]; then
    cluster_sp_id=$(jq -r '.clientId' "${SHARED_DIR}/azure_minimal_permission")
fi

# Assign system role "Contributor" to cluster sp on scope of resource group where cluster to be created.
if [[ -n "${cluster_rg}" ]]; then
    cluster_rg_id=$(az group show -g "${cluster_rg}" --query id -otsv)
    echo "Assign role 'Contributor' to ${cluster_rg_id} with scope over resource group ${cluster_rg}"
    az role assignment create --assignee ${cluster_sp_id} --role "Contributor" --scope ${cluster_rg_id} -o jsonc
fi

# Assign system role "Network Contributor" to cluster sp on scope of resource group where vnet reside in
if [[ -n "${vnet_rg}" ]]; then
    vnet_rg_id=$(az group show -g "${vnet_rg}" --query id -otsv)
    echo "Assign role 'Network Contributor' to ${cluster_sp_id} with scope over resource group ${vnet_rg}"
    az role assignment create --assignee ${cluster_sp_id} --role "Network Contributor" --scope ${vnet_rg_id} -o jsonc
fi
