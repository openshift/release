#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Configure ibmcloud
# to find way to store region and ic_api_key
export IBMCLOUD_CLI=ibmcloud
export IBMCLOUD_HOME=/output
region=$(jq -r .ibmcloud.region ${SHARED_DIR}/metadata.json)
export region
"${IBMCLOUD_CLI}" config --check-version=false

echo "logging in..."
"${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
"${IBMCLOUD_CLI}" plugin list
resource_group_name=$(jq -r .ibmcloud.resourceGroupName ${SHARED_DIR}/metadata.json)
echo resource group is $resource_group_name

ibmcloud resource group $resource_group_name || exit 1
ibmcloud target -g $resource_group_name -r $region
sg=$(ibmcloud is sgs --resource-group-name $resource_group_name --output json | jq -r '.[] | select(.name | contains("cluster-wide"))|.id')
echo "Print resource group in detail"

ibmcloud is sgs --resource-group-name $resource_group_name
echo $sg

CLUSTER_NAME=$(oc get infrastructure cluster -o json | jq -r '.status.apiServerURL' | awk -F.  '{print$2}')

echo "Updating security group rules for data-path test on cluster $CLUSTER_NAME"
echo "Adding rule to SG $sg and run NPT"
echo "running ${IBMCLOUD_CLI} is security-group-rule-add $sg inbound tcp --port-min=10000 --port-max=61000 ${IBMCLOUD_CLI} is security-group-rule-add $sg inbound udp --port-min=10000 --port-max=61000"

"${IBMCLOUD_CLI}" is security-group-rule-add $sg inbound tcp --port-min=10000 --port-max=61000
"${IBMCLOUD_CLI}" is security-group-rule-add $sg inbound udp --port-min=10000 --port-max=61000
