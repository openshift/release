#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]] || [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    echo "The installation with minimal permissions is only supported on Azure Public Cloud, no SP or custom role to be destroyed on ${CLUSTER_TYPE}"
    exit 0
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

if [[ -f "${SHARED_DIR}/azure_sp_id" ]]; then
    echo "Deleting sp..."
    sp_ids=$(< "${SHARED_DIR}/azure_sp_id")
    for sp_id in ${sp_ids}; do
        cmd="az ad app delete --id ${sp_id}"
        run_command "${cmd}"
    done
fi

if [[ -f "${SHARED_DIR}/azure_custom_role_name" ]]; then
    role_names=$(< ${SHARED_DIR}/azure_custom_role_name)
    for role_name in ${role_names}; do
        echo "Deleting custom role assigment on scope of subsciption, role name: ${role_name}"
        assigment_id=$(az role assignment list --role ${role_name} --query "[].id" -otsv)
        cmd="az role assignment delete --ids ${assigment_id}"
        run_command "${cmd}"

        echo "Deleting custom role definition, role name: ${role_name}"
        cmd="az role definition delete --name ${role_name}"
        run_command "${cmd}"
    done
fi
