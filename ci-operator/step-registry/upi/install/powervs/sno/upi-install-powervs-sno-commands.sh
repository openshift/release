#!/bin/bash

set -euox pipefail

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

# Creating VSI in PowerVS instance
echo "$(date) Creating VSI in PowerVS instance"
ibmcloud pi instance-create ${POWERVS_VSI_NAME} --image ${POWERVS_IMAGE} --network ${POWERVS_NETWORK} --memory ${POWERVS_VSI_MEMORY} --processors ${POWERVS_VSI_PROCESSORS} --processor-type ${POWERVS_VSI_PROC_TYPE} --sys-type ${POWERVS_VSI_SYS_TYPE} --replicants 1 --replicant-scheme suffix

instance_id=$(ibmcloud pi instances --json | jq -r --arg serverName ${POWERVS_VSI_NAME} '.pvmInstances[] | select (.serverName == $serverName ) | .pvmInstanceID')

# Retrieving ip and mac from workers created in ibmcloud powervs
echo "$(date) Retrieving ip and mac from workers created in ibmcloud powervs"
export MAC_ADDRESS=""
export IP_ADDRESS=""
for ((i=1; i<=20; i++)); do
    instance_id=$(ibmcloud pi instances --json | jq -r --arg serverName ${POWERVS_VSI_NAME} '.pvmInstances[] | select (.serverName == $serverName ) | .pvmInstanceID')
    if [ -z "$instance_id" ]; then
        echo "$(date) Waiting for instance id to be populated"
        sleep 60
        continue
    fi
    break
done

for ((i=1; i<=20; i++)); do
    instance_info=$(ibmcloud pi instance $instance_id --json)
    MAC_ADDRESS=$(echo "$instance_info" | jq -r '.networks[].macAddress')
    IP_ADDRESS=$(echo "$instance_info" | jq -r '.networks[].ipAddress')

    if [ -z "$MAC_ADDRESS" ] || [ -z "$IP_ADDRESS" ]; then
        echo "$(date) Waiting for mac and ip to be populated in $POWERVS_VSI_NAME"
        sleep 60
        continue
    fi

    break
done

if [ -z "$MAC_ADDRESS" ] || [ -z "$IP_ADDRESS" ]; then
  echo "Required mac and ip addresses not collected, exiting test"
  exit 1
fi

# Retrieving wwn from VSI to form the installation disk
volume_wwn=$(ibmcloud pi inlv $instance_id --json | jq -r '.volumes[].wwn')

if [ -z "$volume_wwn" ]; then
    echo "Required volume WWN not collected, exiting test"
    exit 1
fi

# Forming installation disk, ',,' to convert to lower case
INSTALLATION_DISK=$(printf "/dev/disk/by-id/wwn-0x%s" "${volume_wwn,,}")

# Create private key with 0600 permission for ssh purpose
SSH_PRIVATE="/tmp/ssh-privatekey"
cp "/etc/sno-power-credentials/ssh-privatekey" ${SSH_PRIVATE}
chmod 0600 ${SSH_PRIVATE}

SSH_OPTIONS=(-o 'PreferredAuthentications=publickey' -o 'StrictHostKeyChecking=no' -o 'ServerAliveInterval=60' -o 'ServerAliveCountMax=60' -o 'UserKnownHostsFile=/dev/null' -i "${SSH_PRIVATE}")

# https://codeload.github.com/ppc64le-cloud/ocp-sno-hacks/zip/refs/heads/main contains the scripts to setup the SNO cluster
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "mkdir ${BASTION_CI_SCRIPTS_DIR} && cd ${BASTION_CI_SCRIPTS_DIR} && curl https://codeload.github.com/ppc64le-cloud/ocp-ci-hacks/zip/refs/heads/main -o ocp-ci-hacks.zip && unzip ocp-ci-hacks.zip && mv ocp-ci-hacks-main/sno/* ${BASTION_CI_SCRIPTS_DIR} && rm -rf ocp-ci-hacks.zip ocp-ci-hacks-main"

# Setting up the SNO config, generating the ignition and network boot on the bastion
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR} && ./setup-sno.sh ${CLUSTER_NAME} ${BASE_DOMAIN} ${POWERVS_MACHINE_NETWORK_CIDR} ${INSTALLATION_DISK} $(eval "echo ${LIVE_ROOTFS_URL}") $(eval "echo ${LIVE_KERNEL_URL}") $(eval "echo ${LIVE_INITRAMFS_URL}") $(printf "http://%s" "${BASTION}") ${MAC_ADDRESS} ${IP_ADDRESS}"

# Creating dns records in ibmcloud cis service for SNO node to reach hosted cluster and for ingress purpose
ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type A --name "api.${CLUSTER_NAME}" --content "${IP_ADDRESS}"
ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type A --name "api-int.${CLUSTER_NAME}" --content "${IP_ADDRESS}"
ibmcloud cis dns-record-create ${CIS_DOMAIN_ID} --type A --name "*.apps.${CLUSTER_NAME}" --content "${IP_ADDRESS}"

sleep 180

# Rebooting the node to boot from net
ibmcloud pi instance-soft-reboot $instance_id

# Updating the boot disk of SNO node to volume attached to VSI
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR} && ./update-boot-disk.sh ${IP_ADDRESS} ${INSTALLATION_DISK}" &

# Run bootstrap-complete
# Sometimes bootstrap-complete may timeout, but still install-complete can be tried so set +e
set +e
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "openshift-install --dir=${BASTION_CI_SCRIPTS_DIR} wait-for bootstrap-complete --log-level debug"

# set -e to capture on install-complete command
set -e

# Run install-complete
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "openshift-install --dir=${BASTION_CI_SCRIPTS_DIR} wait-for install-complete --log-level debug"
