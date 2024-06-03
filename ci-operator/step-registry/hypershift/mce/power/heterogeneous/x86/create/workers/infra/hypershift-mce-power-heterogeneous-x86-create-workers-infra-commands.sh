#!/bin/bash

set -x

# Agent hosted cluster configs
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME

# VPC VSI(Virtual Server Instance) configs
VPC_VSI_NAME="hcp-ci-${HOSTED_CLUSTER_NAME}-worker"
PROFILE_NAME="bx2-2x8"
IMAGE_ID="r014-63b824ce-ee4b-4494-b92f-f888630746c5"
SSH_KEY_ID="r014-088de8a9-1b11-47b5-927d-80cad45ce921"

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

# Install vpc plugin
ibmcloud plugin install vpc-infrastructure

# Creating x86 VM in VPC
echo "$(date) Creating x86 VSI for VPC"
INSTANCE_NAMES=()
if [ ${HYPERSHIFT_NODE_COUNT} -eq 1 ]; then
  INSTANCE_NAMES+=("${VPC_VSI_NAME}")
else
  for (( i = 1; i <= ${HYPERSHIFT_NODE_COUNT}; i++ )); do
    INSTANCE_NAMES+=("${VPC_VSI_NAME}-${i}")
  done
fi
IP_X86_ADDRESSES=()
for instance in "${INSTANCE_NAMES[@]}"; do
  instance_ip=$(ibmcloud is instance-create $instance "${VPC_NAME}" "${VPC_ZONE}" ${PROFILE_NAME} "${VPC_SUBNET_ID}" --image "${IMAGE_ID}" --key-ids "${SSH_KEY_ID}" --output JSON | jq -r '.primary_network_attachment.primary_ip.address')
  sleep 2
  IP_X86_ADDRESSES+=("$instance_ip")
done
# Save VMs information to ${SHARED_DIR} for use in other scenarios.
echo "${IP_X86_ADDRESSES[@]}" > "${SHARED_DIR}/ipx86addr"
echo "${INSTANCE_NAMES[@]}" > "${SHARED_DIR}/ipx86names"
