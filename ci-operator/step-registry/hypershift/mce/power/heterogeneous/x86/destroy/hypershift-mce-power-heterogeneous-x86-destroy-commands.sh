#!/bin/bash

set -x

# Agent hosted cluster configs
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME

LB_NAME="${HOSTED_CLUSTER_NAME}-lb"

# VPC VSI(Virtual Server Instance) configs
VSI_NAME="${HOSTED_CLUSTER_NAME}-worker-x"
INSTANCE_NAMES=()
if [ ${HYPERSHIFT_NODE_COUNT} -eq 1 ]; then
  INSTANCE_NAMES+=("${VSI_NAME}")
else
  for (( i = 1; i <= ${HYPERSHIFT_NODE_COUNT}; i++ )); do
    INSTANCE_NAMES+=("${VSI_NAME}-${i}")
  done
fi

# Installing required tools
echo "$(date) Installing required tools"
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.16.1/IBM_Cloud_CLI_2.16.1_amd64.tar.gz
tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

# IBM cloud login
echo | ibmcloud login --apikey @"${AGENT_POWER_CREDENTIALS}/ibmcloud-apikey" -r "${VPC_REGION}"

# Target resource group
ibmcloud target -g "${RESOURCE_GROUP_NAME}"

# Delete VPC VSIs
for instance in "${INSTANCE_NAMES[@]}"; do
    ibmcloud is instance-delete "${instance}" -f
    sleep 1
done

# Delete Load Balancer
ibmcloud is load-balancer-delete ${LB_NAME} -f
