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
if [[ "${AZURE_INSTALL_USE_MINIMAL_PERMISSIONS}" == "yes" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/installer-sp-minter.json" ]]; then
    echo "AZURE_INSTALL_USE_MINIMAL_PERMISSIONS is set to yes, and detect installer-sp-minter.json, set AZURE_AUTH_LOCATION to installer-sp-minter.json "
    AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/installer-sp-minter.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]] || [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    echo "The installation with minimal permissions is only supported on Azure Public Cloud, no SP or custom role to be destroyed on ${CLUSTER_TYPE}"
    exit 0
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

if [[ -f "${SHARED_DIR}/azure_sp_id" ]]; then
    echo "Deleting sp..."
    sp_ids=$(< "${SHARED_DIR}/azure_sp_id")
    for sp_id in ${sp_ids}; do
        cmd="az ad app delete --id ${sp_id}"
        # app registration / service principal starting with ci-op- or ci-ln- will be pruned by DPP
        # continue custom role deprovision once {cmd} here failed
        run_command "${cmd}" || true
    done
fi

if [[ -f "${SHARED_DIR}/azure_custom_role_name" ]]; then
    role_names=$(jq -r 'values[]' "${SHARED_DIR}/azure_custom_role_name")
    for role_name in ${role_names}; do
        echo "Deleting custom role assigment, role name: ${role_name}"
        assigment_id_list=$(az role assignment list --all --query "[?roleDefinitionName=='${role_name}'].id" -otsv)
        echo "Debug: role assignment id list to be deleted - ${assigment_id_list}"
        for assigment_id in ${assigment_id_list}; do
            cmd="az role assignment delete --ids ${assigment_id}"
            run_command "${cmd}"
        done

        echo "Deleting custom role definition, role name: ${role_name}"
        cmd="az role definition delete --name ${role_name}"
        run_command "${cmd}"
    done
fi
