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

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output   
    region="${LEASED_RESOURCE}"
    export region
    "${IBMCLOUD_CLI}" config --check-version=false
    echo "Try to login..." 
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

function create_resource_group() {
    local rg="$1" id
    echo "create resource group ... ${rg}"
    id=$("${IBMCLOUD_CLI}" resource group-create ${rg} --output json | jq -r .id)
    "${IBMCLOUD_CLI}" target -g ${id} || return 1
    "${IBMCLOUD_CLI}" resource group ${rg} || return 1
}

ibmcloud_login

cluster_name="${NAMESPACE}-${UNIQUE_HASH}"

rg_name="${cluster_name}-rg"
echo "$(date -u --rfc-3339=seconds) - Creating resource group - ${rg_name}"
create_resource_group ${rg_name}
echo "${rg_name}" > "${SHARED_DIR}/ibmcloud_resource_group"

if [[ "${CREATE_CLUSTER_RESOURCE_GROUP}" == "yes" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Creating resource group - ${cluster_name} for cluster install"
    create_resource_group ${cluster_name}
    echo "${cluster_name}" > "${SHARED_DIR}/ibmcloud_cluster_resource_group"
fi
