#!/bin/bash

set -x
set +e

CLUSTER_NAME="$(printf $PROW_JOB_ID|sha256sum|cut -c-20)"
POWERVS_VSI_NAME="${CLUSTER_NAME}-worker"
BASTION_CI_SCRIPTS_DIR="/tmp/${CLUSTER_NAME}-config"

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
echo | ibmcloud login --apikey @"/etc/sno-power-credentials/.powercreds"

# Installing required ibmcloud plugins
echo "$(date) Installing required ibmcloud plugins"
ibmcloud plugin install power-iaas
ibmcloud plugin install cis

# Set target powervs and cis service instance
ibmcloud pi st ${POWERVS_INSTANCE_CRN}
ibmcloud cis instance-set ${CIS_INSTANCE}

# Setting IBMCLOUD_TRACE to true to enable debug logs for pi and cis operations
export IBMCLOUD_TRACE=true

instance_id=$(ibmcloud pi instances --json | jq -r --arg serverName ${POWERVS_VSI_NAME} '.pvmInstances[] | select (.serverName == $serverName ) | .pvmInstanceID')

ibmcloud pi instance-delete ${instance_id}

# Cleanup cis dns records
idToDelete=$(ibmcloud cis dns-records ${CIS_DOMAIN_ID} --name "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}" --output json | jq -r '.[].id')
if [ -n "${idToDelete}" ]; then
  ibmcloud cis dns-record-delete ${CIS_DOMAIN_ID} ${idToDelete}
fi

idToDelete=$(ibmcloud cis dns-records ${CIS_DOMAIN_ID} --name "api.${CLUSTER_NAME}.${BASE_DOMAIN}" --output json | jq -r '.[].id')
if [ -n "${idToDelete}" ]; then
  ibmcloud cis dns-record-delete ${CIS_DOMAIN_ID} ${idToDelete}
fi

idToDelete=$(ibmcloud cis dns-records ${CIS_DOMAIN_ID} --name "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}" --output json | jq -r '.[].id')
if [ -n "${idToDelete}" ]; then
  ibmcloud cis dns-record-delete ${CIS_DOMAIN_ID} ${idToDelete}
fi

# Create private key with 0600 permission for ssh purpose
SSH_PRIVATE="/tmp/ssh-privatekey"
cp "/etc/sno-power-credentials/ssh-privatekey" ${SSH_PRIVATE}
chmod 0600 ${SSH_PRIVATE}

SSH_OPTIONS=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -i "${SSH_PRIVATE}")

# Run cleanup-sno.sh to clean up the things created on bastion for SNO node net boot
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR} && ./cleanup-sno.sh ${CLUSTER_NAME}"