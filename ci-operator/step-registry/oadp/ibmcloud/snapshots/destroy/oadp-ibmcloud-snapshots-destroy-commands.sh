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

function run_command {
    local CMD="$1"
    ret_val=`eval "${CMD}"`
    echo $ret_val
}

#Install yq
pip3 install --no-input yq

echo ""
echo "PWD: `pwd`"
echo "HOME: ${HOME}"

export PATH="${PATH}:${HOME}/.local/bin"
echo "PATH: ${PATH}"
echo ""

if ! test -f $SHARED_DIR/kubeconfig; then
  echo "File kubeconfig does not exist -- skipping."
  exit 0
fi

#Get Cluster name
CLUSTER_NAME=`yq -r '[.clusters ][0][0].name' $SHARED_DIR/kubeconfig`

#Login
ibmcloud_login
echo ""

#Get Resource group that contains cluster name
RG_CMD="""ibmcloud resource groups --output json | jq -r '.[] | select(.name | startswith(\"$CLUSTER_NAME\")) | .name'"""
echo "Running Command: ${RG_CMD}"
RG_NAME=$(run_command "$RG_CMD")
resource_group="${RG_NAME}"

echo "ResourceGroup: ${resource_group}"

#Set Resource Group
echo "Running Command: ibmcloud target -g ${resource_group}"
run_command "ibmcloud target -g ${resource_group}"
echo ""

#Get first source volume
echo "Running Command: ibmcloud is snapshots --output JSON | jq '[.[] | .source_volume][0] | .id'"
SV_ID=$(run_command "ibmcloud is snapshots --output JSON | jq '[.[] | .source_volume][0] | .id'")

echo "Source Volume ID: ${SV_ID}"

while ([ X"${SV_ID}" != X"" ] && [ X"${SV_ID}" != X"null" ]); do
    #Delete snapshot by source volume
    echo "Deleting Snapshot from source volume ${SV_ID}"
    echo "Running Command: ibmcloud is snapshot-delete-from-source ${SV_ID}"
    run_command "ibmcloud is snapshot-delete-from-source ${SV_ID} -f"

    #Give some time to delete
    echo ""
    echo ""
    sleep 60

    #Get next source volume
    echo "Running Command: ibmcloud is snapshots --output JSON | jq '[.[] | .source_volume][0] | .id'"
    SV_ID=$(run_command "ibmcloud is snapshots --output JSON | jq '[.[] | .source_volume][0] | .id'")
    echo "Source Volume ID: ${SV_ID}"
done
echo "Snapshot cleanup complete"

