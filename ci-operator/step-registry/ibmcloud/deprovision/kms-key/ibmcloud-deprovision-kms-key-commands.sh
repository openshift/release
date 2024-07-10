#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output
    region="${LEASED_RESOURCE}"
    rg=$1
    export region
    "${IBMCLOUD_CLI}" config --check-version=false
    echo "Try to login to ${rg}..."
    "${IBMCLOUD_CLI}" login -r ${region} -g ${rg} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

rg_file="${SHARED_DIR}/ibmcloud_resource_group"
if [ -f "${rg_file}" ]; then
    resource_group=$(cat "${rg_file}")
else
    echo "Did not found a provisoned resource group"
    exit 1
fi

echo "ResourceGroup: ${resource_group}"
ibmcloud_login ${resource_group}

key_file="${SHARED_DIR}/ibmcloud_key.json"
cat ${key_file}

keyTypes=("master" "worker" "default")
for keyType in "${keyTypes[@]}"; do
    echo "delete the keys for ${keyType}..."
    keyInfo=$(jq -r .${keyType} ${key_file})
    echo $keyInfo
    if [[ -n "${keyInfo}" ]] && [[ "${keyInfo}" != "null" ]]; then
        id=$(echo $keyInfo | jq -r .id)
        keyid=$(echo $keyInfo | jq -r .keyID)
        run_command "ibmcloud kp key delete ${keyid} -i ${id} -f" || true
        run_command "ibmcloud resource service-instance-delete ${id} -f" || true
    fi
done
