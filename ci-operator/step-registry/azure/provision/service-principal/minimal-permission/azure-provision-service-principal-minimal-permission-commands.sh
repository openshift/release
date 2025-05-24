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

function run_cmd_with_retries()
{
    local cmd="$1" retries="${2:-}"
    local try=0 ret=0
    [[ -z ${retries} ]] && max="20" || max=${retries}
    echo "Trying ${max} times max to run '${cmd}'"

    res=$(eval "${cmd}") || ret=$?
    while [[ ${ret} -ne 0 || -z "${res}" ]] && [ ${try} -lt ${max} ]; do
        echo "'${cmd}' did not return success or return empty, waiting 60 sec....."
        sleep 60
        try=$(( try + 1 ))
        ret=0
        res=$(eval "${cmd}") || ret=$?
    done
    if [ ${try} -eq ${max} ]; then
        echo "Never succeed or Timeout"
        return 1
    fi
    echo "Succeed"
    return 0
}

function create_sp_with_custom_role() {
    local sp_name="$1"
    local custom_role_name="$2"
    local subscription_id="$3"
    local sp_output="$4"

    # create service principal with custom role at the scope of subscription
    # sometimes, failed to create sp as role assignment creation failed, retry
    run_cmd_with_retries_save_output "az ad sp create-for-rbac --role '${custom_role_name}' --name ${sp_name} --scopes /subscriptions/${subscription_id}" "${sp_output}" "5"
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

sp_list=""
[[ "${AZURE_INSTALL_USE_MINIMAL_PERMISSIONS}" == "yes" ]] && sp_list="${sp_list} cluster"
[[ "${ENABLE_MIN_PERMISSION_FOR_STS}" == "true" ]] && sp_list="${sp_list} sts"

if [[ -z "${sp_list}" ]]; then
    echo "Both AZURE_INSTALL_USE_MINIMAL_PERMISSIONS and ENABLE_MIN_PERMISSION_FOR_STS are disabled, skip this step to create service principal with minimal permission!"
    exit 0
fi

for sp_type in ${sp_list}; do
    sp_name="${CLUSTER_NAME}-sp-${sp_type}"
    sp_output="$(mktemp)"
    if [[ -n "${AZURE_PERMISSION_FOR_CLUSTER_SP}" ]] && [[ "${sp_type}" == "cluster" ]]; then
        role_name="${AZURE_PERMISSION_FOR_CLUSTER_SP}"
    else
        [[ ! -f "${SHARED_DIR}/azure_custom_role_name" ]] && echo "Unable to find file <SHARED_DIR>/azure_custom_role_name, abort..." && exit 1
        role_name=$(jq -r ".${sp_type}" "${SHARED_DIR}/azure_custom_role_name")
    fi

    echo "Creating ${sp_type} sp with role ${role_name} granted..."
    create_sp_with_custom_role "${sp_name}" "${role_name}" "${AZURE_AUTH_SUBSCRIPTION_ID}" "${sp_output}"    
    sp_app_id=$(jq -r .appId "${sp_output}")
    sp_id=$(az ad sp show --id ${sp_app_id} --query id -otsv)
    sp_password=$(jq -r .password "${sp_output}")
    sp_tenant=$(jq -r .tenant "${sp_output}")
    if [[ "${sp_app_id}" == "" ]] || [[ "${sp_password}" == "" ]]; then
        echo "Unable to get service principal id or password, exit..."
        exit 1
    fi

    echo "New service principal app id: ${sp_app_id}, id: ${sp_id}"
    os_sp_file_name="azure_minimal_permission"
    if [[ "${sp_type}" != "cluster" ]]; then
        os_sp_file_name="azure_minimal_permission_${sp_type}"
    fi
    cat <<EOF > "${SHARED_DIR}/${os_sp_file_name}"
{"subscriptionId":"${AZURE_AUTH_SUBSCRIPTION_ID}","clientId":"${sp_app_id}","tenantId":"${sp_tenant}","clientSecret":"${sp_password}"}
EOF

    # for destroy
    echo "${sp_app_id}" >> "${SHARED_DIR}/azure_sp_id"
    rm -f ${sp_output}

    # ensure that role assignment creation is successful
    echo "Ensure that role ${role_name} assigned successfully"
    cmd="az role assignment list --role '${role_name}'"
    run_cmd_with_retries "${cmd}"

    if [[ "${role_name}" == "${AZURE_PERMISSION_FOR_CLUSTER_SP}" ]]; then
        az role assignment list --assignee ${sp_app_id} --query '[].id' -otsv >> "${SHARED_DIR}/azure_role_assignment_ids"
    fi
done
