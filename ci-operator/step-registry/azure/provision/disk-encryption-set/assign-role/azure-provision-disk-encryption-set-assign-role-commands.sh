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

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function run_command_with_retries()
{
    local try=0 cmd="$1" retries="${2:-}" ret=0
    [[ -z ${retries} ]] && max="20" || max=${retries}
    echo "Trying ${max} times max to run '${cmd}'"

    eval "${cmd}" || ret=$?
    while [ X"${ret}" != X"0" ] && [ ${try} -lt ${max} ]; do
        echo "'${cmd}' did not return success, waiting 60 sec....."
        sleep 60
        try=$((try + 1))
        ret=0
        eval "${cmd}" || ret=$?
    done
    if [ ${try} -eq ${max} ]; then
        echo "Never succeed or Timeout"
        return 1
    fi
    echo "Succeed"
    return 0
}

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}


rg_file="${SHARED_DIR}/resourcegroup"
if [ -f "${rg_file}" ]; then
    RESOURCE_GROUP=$(cat "${rg_file}")
else
    echo "Did not found an provisoned empty resource group"
    exit 1
fi

run_command "az group show --name $RESOURCE_GROUP"; ret=$?
if [ X"$ret" != X"0" ]; then
    echo "The $RESOURCE_GROUP resrouce group does not exit"
    exit 1
fi

AZURE_DES_FILE="${SHARED_DIR}/azure_des.json"
cluster_sp_id=$(cat "${AZURE_AUTH_LOCATION}" | jq -r ".clientId")
role_name="Owner"
if [[ "${AZURE_INSTALL_USE_MINIMAL_PERMISSIONS}" == "yes" ]]; then
    role_name=$(< "${SHARED_DIR}/azure_custom_role_name" jq -r .cluster)
    if [[ -z "${role_name}" ]]; then
        echo "Could not find cluster custom role name in file <SHARED_DIR>/azure_custom_role_name, which is created in step 'azure-provision-service-principal-minimal-permission'"
        exit 1
    fi
    cluster_sp_id=$(< "${SHARED_DIR}/azure_minimal_permission" jq -r .clientId)
fi
des_name_list=$(jq -r 'values[]' ${AZURE_DES_FILE})
for des_name in ${des_name_list}; do
    echo "Granting role ${role_name} permissions to cluster service principal on scope of the DiskEncryptionSet: ${des_name}"
    des_id=$(az disk-encryption-set show -n "${des_name}" -g "${RESOURCE_GROUP}" --query "[id]" -o tsv)
    run_command_with_retries "az role assignment create --assignee ${cluster_sp_id} --role ${role_name} --scope ${des_id} -o jsonc" 5
done
