#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Configure ibmcloud
# Store region and ic_api_key
export IBMCLOUD_CLI=ibmcloud
export REGION=$(jq -r .ibmcloud.region ${SHARED_DIR}/metadata.json)
"${IBMCLOUD_CLI}" config --check-version=false

echo "Logging in..."
"${IBMCLOUD_CLI}" login -r ${REGION} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
"${IBMCLOUD_CLI}" plugin list
RESOURCE_GROUP_NAME=$(jq -r .ibmcloud.resourceGroupName ${SHARED_DIR}/metadata.json)
echo "Resource Group is ${RESOURCE_GROUP_NAME}"

"${IBMCLOUD_CLI}" resource group ${RESOURCE_GROUP_NAME} || exit 1
"${IBMCLOUD_CLI}" target -g ${RESOURCE_GROUP_NAME} -r ${REGION}
SG=$(${IBMCLOUD_CLI} is sgs --resource-group-name ${RESOURCE_GROUP_NAME} --output json | jq -r '.[] | select(.name | contains("cluster-wide"))|.id')
echo "Print security group in detail"

ibmcloud is sgs --resource-group-name ${RESOURCE_GROUP_NAME}
echo ${SG}

CLUSTER_NAME=$(oc get infrastructure cluster -o json | jq -r '.status.apiServerURL' | awk -F.  '{print$2}')

echo "Updating security group rules for data-path test on cluster $CLUSTER_NAME"
echo "Adding rule to Security Group ${SG} and run NPT"
echo "Running ${IBMCLOUD_CLI} is security-group-rule-add ${SG} inbound tcp --port-min=10000 --port-max=61000 ${IBMCLOUD_CLI} is security-group-rule-add ${SG} inbound udp --port-min=10000 --port-max=61000"

"${IBMCLOUD_CLI}" is security-group-rule-add ${SG} inbound tcp --port-min=10000 --port-max=61000
"${IBMCLOUD_CLI}" is security-group-rule-add ${SG} inbound udp --port-min=10000 --port-max=61000
