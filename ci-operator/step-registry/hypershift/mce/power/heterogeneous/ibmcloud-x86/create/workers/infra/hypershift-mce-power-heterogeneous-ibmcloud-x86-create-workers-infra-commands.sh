#!/bin/bash

set -x

# Agent hosted cluster configs
HOSTED_CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME

# VPC VSI(Virtual Server Instance) configs
VPC_VSI_NAME="x86-${HOSTED_CLUSTER_NAME}-worker"
PROFILE_NAME="bx2-2x8"
IMAGE_ID="r034-33250be2-61bb-4837-9cd5-6ef83c2ccb2c"
SSH_KEY_ID="r034-55ccc38b-cad7-4244-bad0-6bb4c25cf0e7"

# Fetch VPC details
if [[ -z "${VPC_REGION}" ]]; then
      VPC_REGION=$(jq -r '.vpcRegion' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
fi
if [[ -z "${VPC_ZONE}" ]]; then
      VPC_ZONE=$(jq -r '.vpcZone' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
fi
if [[ -z "${VPC_NAME}" ]]; then
      VPC_NAME=$(jq -r '.vpcName' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
fi
if [[ -z "${VPC_SUBNET_ID}" ]]; then
      VPC_SUBNET_ID=$(jq -r '.vpcSubnetID' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
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

# Install vpc plugin
ibmcloud plugin install vpc-infrastructure

# Updating AgentServiceConfig with x86 osImages
CLUSTER_VERSION=$(oc get clusterversion -o jsonpath={..desired.version} | cut -d '.' -f 1,2)
OS_IMAGES=$(jq --arg CLUSTER_VERSION "${CLUSTER_VERSION}" '[.[] | select(.openshift_version == $CLUSTER_VERSION)]' "${SHARED_DIR}/default_os_images.json")
# shellcheck disable=SC2034
VERSION=$(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "x86_64").version')
# shellcheck disable=SC2034
URL=$(echo "$OS_IMAGES" | jq -r '.[] | select(.cpu_architecture == "x86_64").url')
echo "$(date) Updating AgentServiceConfig"
oc patch AgentServiceConfig agent --type=json -p="[{\"op\": \"add\", \"path\": \"/spec/osImages/-\", \"value\": {\"openshiftVersion\": \"${CLUSTER_VERSION}\", \"version\": \"${VERSION}\", \"url\": \"${URL}\",  \"cpuArchitecture\": \"x86_64\"}}]"
oc get AgentServiceConfig agent -o yaml

oc wait --timeout=5m --for=condition=DeploymentsHealthy agentserviceconfig agent
echo "$(date) AgentServiceConfig updated"

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
  ibmcloud is instance-create $instance "${VPC_NAME}" "${VPC_ZONE}" ${PROFILE_NAME} "${VPC_SUBNET_ID}" --image "${IMAGE_ID}" --keys "${SSH_KEY_ID}"
  sleep 5
  instance_ip=$(ibmcloud is instance $instance --output JSON | jq -r '.primary_network_attachment.primary_ip.address')
  IP_X86_ADDRESSES+=("$instance_ip")
done

# Save VMs information to ${SHARED_DIR} for use in other scenarios.
echo "${IP_X86_ADDRESSES[@]}" > "${SHARED_DIR}/ipx86addr"
echo "${INSTANCE_NAMES[@]}" > "${SHARED_DIR}/ipx86names"

# Schedule ingress controller pods on all worker nodes.
oc patch ingresscontroller default -n openshift-ingress-operator -p '{"spec": {"nodePlacement": {"nodeSelector": { "matchLabels": { "node-role.kubernetes.io/worker": ""}}}}}' --type=merge --kubeconfig=${SHARED_DIR}/nested_kubeconfig
