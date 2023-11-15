#!/bin/bash

set -x
set +e

# Agent hosted cluster configs
HOSTED_CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"

# PowerVS VSI(Virtual Server Instance) configs
POWERVS_VSI_NAME="${HOSTED_CLUSTER_NAME}-worker"

# Installing required tools
mkdir /tmp/bin
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.16.1/IBM_Cloud_CLI_2.16.1_amd64.tar.gz
tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

# IBM cloud login
echo  | ibmcloud login --apikey @"${AGENT_POWER_CREDENTIALS}/ibmcloud-apikey"

# Installing ibmcloud required plugins
ibmcloud plugin install power-iaas
ibmcloud plugin install cis

# Set target powervs and cis service instance
ibmcloud pi st ${POWERVS_INSTANCE_CRN}
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
    instance_id=$(ibmcloud pi instances --json | jq -r --arg serverName $instance '.pvmInstances[] | select (.serverName == $serverName ) | .pvmInstanceID')
    if [ -z "$instance_id" ]; then
        continue
    fi
    INSTANCE_ID+=("$instance_id")
done
for instance in "${INSTANCE_ID[@]}"; do
    for ((i=1; i<=15; i++)); do
        instance_info=$(ibmcloud pi instance $instance --json)
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
    ibmcloud pi instance-delete $instance
done

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

# Create private key with 0600 permission for ssh purpose
cp "${AGENT_POWER_CREDENTIALS}/ssh-privatekey" /tmp/ssh-privatekey
chmod 0600 /tmp/ssh-privatekey

serverArgs=""
for (( i = 0; i < ${HYPERSHIFT_NODE_COUNT}; i++ )); do
    serverArgs+="${INSTANCE_NAMES[i]} "
done

# Cleanup bastion to remove network boot configurations
ssh -o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i /tmp/ssh-privatekey root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR} && ./cleanup-pxe-boot.sh ${HOSTED_CLUSTER_NAME} ${HYPERSHIFT_NODE_COUNT} ${serverArgs}"
