#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

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

function deleteDedicatedHost() {
    local dhName=$1 status
    dhg=$(${IBMCLOUD_CLI} is dh ${dhName} --output JSON | jq -r '.group.name')
    status=$(${IBMCLOUD_CLI} is dh ${dhName} --output JSON | jq -r ."lifecycle_state")

    if [[ "${status}" = "stable" ]]; then
        run_command "${IBMCLOUD_CLI} is dhu ${dhName} --enabled false"
    fi

    run_command "${IBMCLOUD_CLI} is dhd ${dhName} -f"
    run_command "${IBMCLOUD_CLI} is dhgd ${dhg} -f"
}

ibmcloud_login

#the file which saved the resource group of the pre created dedicated host group (just created when create the pre dedicated host, and not in Default group).
dhgRGFile="${SHARED_DIR}/ibmcloud_resource_group"
dh_file=${SHARED_DIR}/dedicated_host

dhgRG=$(cat ${dhgRGFile})

run_command "ibmcloud target -g ${dhgRG}"

if [ -f ${dh_file} ]; then
    dhName=$(cat ${dh_file})
    echo "try to delete the dedicated host for master nodes and worker nodes ..."
    deleteDedicatedHost ${dhName}
fi

mapfile -t dhs < <(ibmcloud is dhs --resource-group-name ${dhgRG} -q | awk '(NR>1) {print $2}')
if [[ ${#dhs[@]} != 0 ]]; then
    echo "ERROR: fail to clean up the pre created dedicated host in ${dhgRG}:" "${dhs[@]}"
    exit 1
fi
