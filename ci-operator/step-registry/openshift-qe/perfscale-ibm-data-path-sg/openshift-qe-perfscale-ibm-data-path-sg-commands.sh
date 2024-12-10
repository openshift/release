#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Configure ibmcloud
export IBMCLOUD_CLI=ibmcloud
REGION=$(jq -r .ibmcloud.region ${SHARED_DIR}/metadata.json)
export REGION
"${IBMCLOUD_CLI}" config --check-version=false

echo "Logging in..."
"${IBMCLOUD_CLI}" login -r ${REGION} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"

# Check and install VPC plug-in if missing
if ! "${IBMCLOUD_CLI}" plugin show vpc-infrastructure > /dev/null 2>&1; then
    echo "VPC Infrastructure plug-in not found. Installing..."
    "${IBMCLOUD_CLI}" plugin install vpc-infrastructure -f
fi

"${IBMCLOUD_CLI}" plugin list
RESOURCE_GROUP_NAME=$(jq -r .ibmcloud.resourceGroupName ${SHARED_DIR}/metadata.json)
echo "Resource Group is ${RESOURCE_GROUP_NAME}"

# Set target resource group and region
"${IBMCLOUD_CLI}" resource group ${RESOURCE_GROUP_NAME} || exit 1
"${IBMCLOUD_CLI}" target -g ${RESOURCE_GROUP_NAME} -r ${REGION}

# Retrieve security group ID
SG=$("${IBMCLOUD_CLI}" is security-groups --resource-group-name ${RESOURCE_GROUP_NAME} --output json | jq -r '.[] | select(.name | contains("cluster-wide")) | .id')
if [ -z "$SG" ]; then
    echo "No security group found with 'cluster-wide' in its name."
    exit 1
fi

echo "Print security group in detail"
"${IBMCLOUD_CLI}" is security-groups --resource-group-name ${RESOURCE_GROUP_NAME}
echo "Security Group ID: ${SG}"

# Capture cluster name
CLUSTER_NAME=$(oc get infrastructure cluster -o json | jq -r '.status.apiServerURL' | awk -F. '{print $2}')
echo "Updating security group rules for data-path test on cluster $CLUSTER_NAME"

# Add security group rules for data path testing
echo "Adding rule to Security Group ${SG} for TCP and UDP traffic on ports 10000-61000"
"${IBMCLOUD_CLI}" is security-group-rule-add ${SG} inbound tcp --port-min=10000 --port-max=61000
"${IBMCLOUD_CLI}" is security-group-rule-add ${SG} inbound udp --port-min=10000 --port-max=61000

echo "Security group rules are updated successfully."
