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

function run_cmd_with_retries_save_output()
{
    local cmd="$1" output="$2" retries="${3:-}"
    local try=0 ret=0
    [[ -z ${retries} ]] && max="20" || max=${retries}
    echo "Trying ${max} times max to run '${cmd}', save output to ${output}"

    eval "${cmd}" > "${output}" || ret=$?
    while [ X"${ret}" != X"0" ] && [ ${try} -lt ${max} ]; do
        echo "'${cmd}' did not return success, waiting 60 sec....."
        sleep 60
        try=$(( try + 1 ))
        ret=0
        eval "${cmd}" > "${output}" || ret=$?
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
if [[ -f "${CLUSTER_PROFILE_DIR}/installer-sp-minter.json" ]]; then
    AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/installer-sp-minter.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]] || [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    echo "Installation with minimal permissions is only supported on Azure Public Cloud so far, exit..."
    exit 1
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

sp_output="$(mktemp)"
sp_name="${CLUSTER_NAME}-sp-cluster"
run_cmd_with_retries_save_output "az ad sp create-for-rbac --role 'Contributor' --name ${sp_name} --scopes /subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}" "${sp_output}" "5"
sp_id=$(jq -r .appId "${sp_output}")
sp_password=$(jq -r .password "${sp_output}")
sp_tenant=$(jq -r .tenant "${sp_output}")
if [[ "${sp_id}" == "" ]] || [[ "${sp_password}" == "" ]]; then
    echo "Unable to get service principal id or password, exit..."
    exit 1
fi
# save for destroy
az role assignment list --assignee ${sp_id} --query '[].id' -otsv >> "${SHARED_DIR}/azure_role_assignment_ids"

if [[ -n "${AZURE_PERMISSION_FOR_CLUSTER_SP}" ]]; then
    run_command "az role assignment create --assignee ${sp_id} --role '${AZURE_PERMISSION_FOR_CLUSTER_SP}' --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}"
    
    # for destroy
    echo "az role assignment delete --assignee ${sp_id} --role '${AZURE_PERMISSION_FOR_CLUSTER_SP}' --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}" > "${SHARED_DIR}/azure_role_assignment_destroy"
fi

os_sp_file_name="azure_minimal_permission"
cat <<EOF > "${SHARED_DIR}/${os_sp_file_name}"
{"subscriptionId":"${AZURE_AUTH_SUBSCRIPTION_ID}","clientId":"${sp_id}","tenantId":"${sp_tenant}","clientSecret":"${sp_password}"}
EOF

# for destroy
echo "${sp_id}" >> "${SHARED_DIR}/azure_sp_id"
rm -f ${sp_output}
