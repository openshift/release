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
    ibmcloud is volume-update $volume_id  --profile $STORAGE_PROFILE

    echo "Waiting for volume $volume_id to become available..."
    while true; do
        status=$(ibmcloud is vol $volume_id --output json | jq -r .status)
        echo "Volume status: $status"
        if [ "$status" = "available" ]; then
            echo "Volume $volume_id is now available"
            break
        fi
        echo "Waiting 30 seconds before checking again..."
        sleep 30
    done

    ibmcloud is volume $volume_id
}

function add_data_volume() {
    # Get the zone of the instance first
    instance_zone=$(ibmcloud is instance $1 --output json | jq -r '.zone.name')
    echo "Instance $1 is in zone: ${instance_zone}"
    
    echo "Creating volume $1-data-volume for node $1 in zone ${instance_zone}"
    ibmcloud is volume-create $1-data-volume custom ${instance_zone} --capacity 100 --iops 6000 --resource-group-name ${resource_group}
    
    echo "Attaching volume $1-data-volume to instance $1"
    ibmcloud is instance-volume-attachment-add data-attachment $1 $1-data-volume --auto-delete true
}

ibmcloud_login
find_resource_group

nodes=$(oc get nodes -l $NODE_LABEL --no-headers | awk '{print $1}')

for node in $nodes; do 
    echo "node $node"
    add_data_volume $node
done