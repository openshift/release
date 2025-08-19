#!/bin/bash

set -x

# Agent hosted cluster configs
# shellcheck disable=SC2155
export HOSTED_CLUSTER_NAME="$(printf "$PROW_JOB_ID" | sha256sum | cut -c-20)"
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

# Installing generic required tools
echo "$(date) Installing required tools"
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.16.1/IBM_Cloud_CLI_2.16.1_amd64.tar.gz
tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

set_x86_configs() {
  # VPC VSI(Virtual Server Instance) configs
  VPC_VSI_NAME="x86-${HOSTED_CLUSTER_NAME}-worker"
  # The instance profile, which defines the compute resources allocated to the VSI
  PROFILE_NAME=$(jq -r '.x86ProfileName' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
  # The ID of the image used to create the VSI. NOTE: It should be the ID of an image available in your IBM Cloud account
  IMAGE_ID=$(jq -r '.x86ImageID' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
  # The ID of the SSH key you want to inject into the VSI
  SSH_KEY_ID=$(jq -r '.x86sshKeyID' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")

  # Fetching Resource Group
  if [[ -z "${RESOURCE_GROUP_NAME}" ]]; then
        RESOURCE_GROUP_NAME=$(jq -r '.resourceGroupName' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
  fi

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

}

create_x86_vms() {
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
    ibmcloud is instance-create $instance "${VPC_NAME}" "${VPC_ZONE}" ${PROFILE_NAME} "${VPC_SUBNET_ID}" --image "${IMAGE_ID}" --keys "${SSH_KEY_ID}"
    sleep 5
    instance_ip=$(ibmcloud is instance $instance --output JSON | jq -r '.primary_network_attachment.primary_ip.address')
    IP_X86_ADDRESSES+=("$instance_ip")
  done

  # Save VMs information to ${SHARED_DIR} for use in other scenarios.
  echo "${IP_X86_ADDRESSES[@]}" > "${SHARED_DIR}/ipx86addr"
  echo "${INSTANCE_NAMES[@]}" > "${SHARED_DIR}/ipx86names"
  
}

update_agentserviceconfig() {
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

  oc wait --timeout=10m --for=condition=DeploymentsHealthy agentserviceconfig agent
  echo "$(date) AgentServiceConfig updated"

}


set_power_configs() {
  # PowerVS VSI(Virtual Server Instance) configs
  POWERVS_VSI_NAME="power-${HOSTED_CLUSTER_NAME}-worker"
  POWERVS_VSI_MEMORY=$(jq -r '.powervsVSIMemory' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
  POWERVS_VSI_PROCESSORS=$(jq -r '.powervsVSIProcessors' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
  POWERVS_VSI_PROC_TYPE=$(jq -r '.powervsVSIProcType' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
  if [ ${IS_HETEROGENEOUS} == "yes" ]; then
      # NOTE: Using e980 as a workaround for VPC Load Balancer connectivity issues with
      # s922 in heterogeneous node pools, until a permanent fix.
      POWERVS_VSI_SYS_TYPE=$(jq -r '.powervsVSISysType' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
  else
      POWERVS_VSI_SYS_TYPE=$(jq -r '.powervsVSISysType' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
  fi

  MCE_VERSION=$(oc get "$(oc get multiclusterengines -oname)" -ojsonpath="{.status.currentVersion}" | cut -c 1-3)
  HYPERSHIFT_CLI_NAME=hcp
  if (( $(echo "$MCE_VERSION < 2.4" | bc -l) )); then
  echo "MCE version is less than 2.4, use hypershift command"
  HYPERSHIFT_CLI_NAME=hypershift
  fi

  # Installing hypershift cli
  echo "$(date) Installing hypershift cli"
  mkdir /tmp/${HYPERSHIFT_CLI_NAME}_cli
  downURL=$(oc get ConsoleCLIDownload ${HYPERSHIFT_CLI_NAME}-cli-download -o json | jq -r '.spec.links[] | select(.text | test("Linux for x86_64")).href')
  curl -k --output /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz ${downURL}
  tar -xvf /tmp/${HYPERSHIFT_CLI_NAME}.tar.gz -C /tmp/${HYPERSHIFT_CLI_NAME}_cli
  chmod +x /tmp/${HYPERSHIFT_CLI_NAME}_cli/${HYPERSHIFT_CLI_NAME}
  export PATH=$PATH:/tmp/${HYPERSHIFT_CLI_NAME}_cli

}

create_power_vms() {
  # IBM cloud login
  echo | ibmcloud login --apikey @"${AGENT_POWER_CREDENTIALS}/ibmcloud-apikey"

  # Installing required ibmcloud plugins
  echo "$(date) Installing required ibmcloud plugins"
  ibmcloud plugin install power-iaas
  ibmcloud plugin install cis

  # Fetching PowerVS related details
  if [[ -z "${POWERVS_IMAGE}" ]]; then
        POWERVS_IMAGE=$(jq -r '.powervsImage' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
  fi
  if [[ -z "${POWERVS_NETWORK}" ]]; then
        POWERVS_NETWORK=$(jq -r '.powervsNetwork' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
  fi
  if [[ -z "${POWERVS_INSTANCE_CRN}" ]]; then
        if [ ${IS_HETEROGENEOUS} == "yes" ]; then
          POWERVS_INSTANCE_CRN=$(jq -r '.powervsInstanceCRN' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
        else
          POWERVS_INSTANCE_CRN=$(jq -r '.powervsInstanceCRN' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
        fi
  fi
  # Set target powervs service instance
  ibmcloud pi ws tg ${POWERVS_INSTANCE_CRN}


  # Setting IBMCLOUD_TRACE to true to enable debug logs for pi and cis operations
  export IBMCLOUD_TRACE=true

  echo "$(date) Creating VSI in PowerVS instance"
  ibmcloud pi ins create ${POWERVS_VSI_NAME} --image ${POWERVS_IMAGE} --subnets ${POWERVS_NETWORK} --memory ${POWERVS_VSI_MEMORY} --processors ${POWERVS_VSI_PROCESSORS} --processor-type ${POWERVS_VSI_PROC_TYPE} --sys-type ${POWERVS_VSI_SYS_TYPE} --replicants ${HYPERSHIFT_NODE_COUNT} --replicant-scheme suffix --replicant-affinity-policy none

  # Adding sleep as it would take some time for VMs to get alive to retrieve the network interface details like ip and mac
  sleep 90s

  # Retrieving ip and mac from workers created in ibmcloud powervs
  echo "$(date) Retrieving ip and mac from workers created in ibmcloud powervs"
  INSTANCE_NAMES=()
  if [ ${HYPERSHIFT_NODE_COUNT} -eq 1 ]; then
    INSTANCE_NAMES+=("${POWERVS_VSI_NAME}")
  else
    for (( i = 1; i <= ${HYPERSHIFT_NODE_COUNT}; i++ )); do
      INSTANCE_NAMES+=("${POWERVS_VSI_NAME}-${i}")
    done
  fi
  INSTANCE_ID=()
  for instance in "${INSTANCE_NAMES[@]}"; do
      for ((i=1; i<=20; i++)); do
          instance_id=$(ibmcloud pi ins ls --json | jq -r --arg serverName $instance '.pvmInstances[] | select (.name == $serverName ) | .id')
          if [ -z "$instance_id" ]; then
              echo "$(date) Waiting for id to be populated for $instance"
              sleep 60
              continue
          fi
          INSTANCE_ID+=("$instance_id")
          break
      done
  done

  MAC_ADDRESSES=()
  IP_ADDRESSES=()
  origins=""
  for instance in "${INSTANCE_ID[@]}"; do
      for ((i=1; i<=20; i++)); do
          instance_info=$(ibmcloud pi ins get $instance --json)
          mac_address=$(echo "$instance_info" | jq -r '.networks[].macAddress')
          ip_address=$(echo "$instance_info" | jq -r '.networks[].ipAddress')
          instance_name=$(echo "$instance_info" | jq -r '.serverName')

          if [ -z "$mac_address" ] || [ -z "$ip_address" ]; then
              echo "$(date) Waiting for mac and ip to be populated for $instance"
              sleep 60
              continue
          fi

          MAC_ADDRESSES+=("$mac_address")
          IP_ADDRESSES+=("$ip_address")
          origins+="{\"name\": \"${instance_name}\", \"address\": \"${ip_address}\", \"enabled\": true},"
          break
      done
  done

  if [ ${#MAC_ADDRESSES[@]} -ne ${HYPERSHIFT_NODE_COUNT} ] || [ ${#IP_ADDRESSES[@]} -ne ${HYPERSHIFT_NODE_COUNT} ]; then
    echo "Required VM's addresses not collected, exiting test"
    echo "Collected MAC Address: ${MAC_ADDRESSES[]}, IP Address: ${IP_ADDRESSES[]}}"
    exit 1
  fi

   # Save VMs ips to ${SHARED_DIR} for use in other scenarios.
   echo "${IP_ADDRESSES[@]}" > "${SHARED_DIR}/ippoweraddr"
   echo "${INSTANCE_NAMES[@]}" > "${SHARED_DIR}/inspowernames"
   echo "${MAC_ADDRESSES[@]}" > "${SHARED_DIR}/macpoweraddr"
   echo "${origins}" > "${SHARED_DIR}/origins"
}

setup_power_infra() {
  # Setup specific configurations/install tools
  set_power_configs
  # power VMs are created inside PowerVS service of IBM Cloud.
  create_power_vms
}

setup_x86_infra() {
  # Setup specific configurations
  set_x86_configs
  # x86 VMs are created inside VPC service of IBM Cloud.
  create_x86_vms
  update_agentserviceconfig
}

main() {
    setup_power_infra
    if [ ${IS_HETEROGENEOUS} == "yes" ]; then
      setup_x86_infra
    fi
}

main