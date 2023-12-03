#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    # Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
    chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
    source ${SHARED_DIR}/azurestack-login-script.sh
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

list_vnet_tags="${SHARED_DIR}/list_azure_existing_vnet_tags.sh"
if [ -f "${list_vnet_tags}" ]; then
    sh -x "${list_vnet_tags}"
fi

remove_resources_by_cli="${SHARED_DIR}/remove_resources_by_cli.sh"
if [ -f "${remove_resources_by_cli}" ]; then
    sh -x "${remove_resources_by_cli}"
fi

rg_files="${SHARED_DIR}/resourcegroup ${SHARED_DIR}/resourcegroup_cluster ${SHARED_DIR}/RESOURCE_GROUP_NAME"
for rg_file in ${rg_files}; do
    if [ -f "${rg_file}" ]; then
        existing_rg=$(cat "${rg_file}")
        if [ "$(az group exists -n "${existing_rg}")" == "true" ]; then
            az group delete -y -n "${existing_rg}"
        fi
    fi
done
