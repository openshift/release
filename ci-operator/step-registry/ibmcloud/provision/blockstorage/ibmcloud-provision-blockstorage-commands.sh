#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

function find_resource_group() {

    resource_group=$(jq -r .ibmcloud.resourceGroupName ${SHARED_DIR}/metadata.json)
    echo "create resource group ... ${resource_group}"
    ibmcloud target -g ${resource_group}
}

function update_volume() {

    volume_id=$(ibmcloud is instance $1 --output json | jq -r '.volume_attachments[0].volume.id')
    ibmcloud is volume-update $volume_id --iops 5000

    ibmcloud is volume $volume_id
}

ibmcloud_login
find_resource_group

nodes=$(oc get nodes -l $NODE_LABEL --no-headers | awk '{print $1}')

for node in $nodes; do 
    echo "node $node"
    update_volume $node
done
