#!/bin/bash

set -x
set +e

# Agent hosted cluster configs
HOSTED_CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
export HOSTED_CLUSTER_NAME

# PowerVS VSI(Virtual Server Instance) configs
POWERVS_VSI_NAME="power-${HOSTED_CLUSTER_NAME}-worker"

# Fetching Domain
if [[ -z "${HYPERSHIFT_BASE_DOMAIN}" ]]; then
		HYPERSHIFT_BASE_DOMAIN=$(jq -r '.hypershiftBaseDomain' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
fi

# Fetching Resource Group Name
if [[ -z "${RESOURCE_GROUP_NAME}" ]]; then
    RESOURCE_GROUP_NAME=$(jq -r '.resourceGroupName' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
fi

# Fetching CIS related details
if [[ -z "${CIS_INSTANCE}" ]]; then
		CIS_INSTANCE=$(jq -r '.cisInstance' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
fi
if [[ -z "${CIS_DOMAIN_ID}" ]]; then
		CIS_DOMAIN_ID=$(jq -r '.cisDomainID' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
fi

# Fetching Bastion related details
if [[ -z "${BASTION_CI_SCRIPTS_DIR}" ]]; then
    BASTION_CI_SCRIPTS_DIR=$(jq -r '.bastionScriptsDir' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
fi
if [[ -z "${BASTION}" ]]; then
    if [ ${IS_HETEROGENEOUS} == "yes" ]; then
          BASTION=$(jq -r '.bastion' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
    else
          BASTION=$(jq -r '.bastion' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
    fi
fi

# Installing required tools
mkdir /tmp/bin
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.16.1/IBM_Cloud_CLI_2.16.1_amd64.tar.gz
tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

delete_power_vms() {
  # IBM cloud login
  echo  | ibmcloud login --apikey @"${AGENT_POWER_CREDENTIALS}/ibmcloud-apikey"

  # Installing ibmcloud required plugins
  ibmcloud plugin install power-iaas
  ibmcloud plugin install cis

  # Set target powervs and cis service instance
  if [[ -z "${POWERVS_INSTANCE_CRN}" ]]; then
        if [ ${IS_HETEROGENEOUS} == "yes" ]; then
          POWERVS_INSTANCE_CRN=$(jq -r '.powervsInstanceCRN' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
        else
          POWERVS_INSTANCE_CRN=$(jq -r '.powervsInstanceCRN' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources.json")
        fi
  fi
  ibmcloud pi ws tg ${POWERVS_INSTANCE_CRN}
  ibmcloud cis instance-set ${CIS_INSTANCE}

  export IBMCLOUD_TRACE=true

  # Ensure VSIs are in ACTIVE or ERROR state before attempting instance-delete or else it will fail
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
      instance_id=$(ibmcloud pi ins ls --json | jq -r --arg serverName $instance '.pvmInstances[] | select (.name == $serverName ) | .id')
      if [ -z "$instance_id" ]; then
          continue
      fi
      INSTANCE_ID+=("$instance_id")
  done
  for instance in "${INSTANCE_ID[@]}"; do
      for ((i=1; i<=15; i++)); do
          instance_info=$(ibmcloud pi ins get $instance --json)
          instance_status=$(echo "$instance_info" | jq -r '.status')
          if [ "$instance_status" = "ERROR" ] || [ "$instance_status" = "ACTIVE" ];  then
            break
          fi
          echo "waiting for vm $instance to reach a final state, current state: $instance_status"
          sleep 60
      done
  done

  # Delete VSI
  for instance in "${INSTANCE_ID[@]}"; do
      ibmcloud pi ins del $instance
  done
}

cleanup_other_resources() {
  # Cleanup cis dns records
  idToDelete=$(ibmcloud cis dns-records ${CIS_DOMAIN_ID} --name "*.apps.${HOSTED_CLUSTER_NAME}.${HYPERSHIFT_BASE_DOMAIN}" --output json | jq -r '.[].id')
  if [ -n "${idToDelete}" ]; then
    ibmcloud cis dns-record-delete ${CIS_DOMAIN_ID} ${idToDelete}
  fi

  idToDelete=$(ibmcloud cis dns-records ${CIS_DOMAIN_ID} --name "api.${HOSTED_CLUSTER_NAME}.${HYPERSHIFT_BASE_DOMAIN}" --output json | jq -r '.[].id')
  if [ -n "${idToDelete}" ]; then
    ibmcloud cis dns-record-delete ${CIS_DOMAIN_ID} ${idToDelete}
  fi

  idToDelete=$(ibmcloud cis dns-records ${CIS_DOMAIN_ID} --name "api-int.${HOSTED_CLUSTER_NAME}.${HYPERSHIFT_BASE_DOMAIN}" --output json | jq -r '.[].id')
  if [ -n "${idToDelete}" ]; then
    ibmcloud cis dns-record-delete ${CIS_DOMAIN_ID} ${idToDelete}
  fi

  if [ ${USE_GLB} == "yes" ]; then
    idToDelete=$(ibmcloud cis glbs ${CIS_DOMAIN_ID} -i ${CIS_INSTANCE} | grep ${HOSTED_CLUSTER_NAME} | awk ' { print $1 }')
    if [ -n "${idToDelete}" ]; then
      ibmcloud cis glb-delete ${CIS_DOMAIN_ID} -i ${CIS_INSTANCE} ${idToDelete}
    fi

    idToDelete=$(ibmcloud cis glb-pools -i ${CIS_INSTANCE} | grep ${HOSTED_CLUSTER_NAME} | awk ' { print $1 }')
    if [ -n "${idToDelete}" ]; then
      ibmcloud cis glb-pool-delete -i ${CIS_INSTANCE} ${idToDelete}
    fi
  fi

  # Create private key with 0600 permission for ssh purpose
  cp "${AGENT_POWER_CREDENTIALS}/ssh-privatekey" /tmp/ssh-privatekey
  chmod 0600 /tmp/ssh-privatekey

  serverArgs=""
  for (( i = 0; i < ${HYPERSHIFT_NODE_COUNT}; i++ )); do
      serverArgs+="${INSTANCE_NAMES[i]} "
  done

  # Cleanup bastion to remove network boot configurations
  ssh -o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i /tmp/ssh-privatekey root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR} && ./cleanup-pxe-boot.sh ${HOSTED_CLUSTER_NAME} ${HYPERSHIFT_NODE_COUNT} ${serverArgs}"
}

delete_x86_vms() {
  # VPC VSI(Virtual Server Instance) configs
  VSI_NAME="x86-${HOSTED_CLUSTER_NAME}-worker"
  INSTANCE_NAMES=()
  if [ ${HYPERSHIFT_NODE_COUNT} -eq 1 ]; then
    INSTANCE_NAMES+=("${VSI_NAME}")
  else
    for (( i = 1; i <= ${HYPERSHIFT_NODE_COUNT}; i++ )); do
      INSTANCE_NAMES+=("${VSI_NAME}-${i}")
    done
  fi

  # Fetch VPC Region
  if [[ -z "${VPC_REGION}" ]]; then
        VPC_REGION=$(jq -r '.vpcRegion' "${AGENT_POWER_CREDENTIALS}/ibmcloud-resources-het.json")
  fi
  ibmcloud target -r "${VPC_REGION}"
  # Target resource group
  ibmcloud target -g "${RESOURCE_GROUP_NAME}"
  # Install vpc plugin
  ibmcloud plugin install vpc-infrastructure

  # Delete VPC VSIs
  for instance in "${INSTANCE_NAMES[@]}"; do
      ibmcloud is instance-delete "${instance}" -f
      sleep 1
  done
}

delete_security_groups() {
  RULE_ID=$(cat "${SHARED_DIR}/rule_id")
  SECURITY_GROUP_ID=$(ibmcloud is load-balancer "${LB_NAME}" --output JSON | jq -r '.security_groups[].id')
  ibmcloud is security-group-rule-delete ${SECURITY_GROUP_ID} ${RULE_ID} -f
}

delete_lb() {
  # Clean up the security groups associated with the LB
  delete_security_groups
  # Delete Load Balancer
  ibmcloud is load-balancer-delete ${LB_NAME} -f
}

main() {
  delete_power_vms
  cleanup_other_resources
  if [ ${IS_HETEROGENEOUS} == "yes" ]; then
    LB_NAME="lb-${HOSTED_CLUSTER_NAME}"
    delete_x86_vms
    delete_lb
  fi
}

main