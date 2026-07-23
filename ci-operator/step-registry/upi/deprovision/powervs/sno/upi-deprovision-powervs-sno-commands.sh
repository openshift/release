#!/bin/bash

set -x
set +e

CLUSTER_NAME="cicd-$(printf $PROW_JOB_ID|sha256sum|cut -c-10)"
POWERVS_VSI_NAME="${CLUSTER_NAME}-worker"
BASTION_CI_SCRIPTS_DIR="/tmp/${CLUSTER_NAME}-config"

if [ -f "${SHARED_DIR}/kubeconfig" ]; then
  echo "Test cluster accessiblity"
  if [ -f "${SHARED_DIR}/proxy-conf.sh" ]; then
    source "${SHARED_DIR}/proxy-conf.sh"
  fi
  CLUSTER_INFO="/tmp/cluster-${CLUSTER_NAME}-after-e2e.txt"
  touch ${CLUSTER_INFO}
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  echo "=========== oc get clusterversion ==============" >> ${CLUSTER_INFO}
  oc get clusterversion >> ${CLUSTER_INFO}
  echo "=========== oc get node -o wide ==============" >> ${CLUSTER_INFO}
  oc get node -o wide >> ${CLUSTER_INFO}
  echo "=========== oc adm top node ==============" >> ${CLUSTER_INFO}
  oc adm top node >> ${CLUSTER_INFO}
  echo "=========== oc get co -o wide ==============" >> ${CLUSTER_INFO}
  oc get co -o wide >> ${CLUSTER_INFO}
  echo "=========== oc get pod -A -o wide ==============" >> ${CLUSTER_INFO}
  oc get pod -A -o wide >> ${CLUSTER_INFO}
  cp ${CLUSTER_INFO} "${ARTIFACT_DIR}/"
fi

# Installing required tools
echo "$(date) Installing required tools"
mkdir /tmp/ibm_cloud_cli
curl --output /tmp/IBM_CLOUD_CLI_amd64.tar.gz https://download.clis.cloud.ibm.com/ibm-cloud-cli/2.23.0/IBM_Cloud_CLI_2.23.0_amd64.tar.gz
tar xvzf /tmp/IBM_CLOUD_CLI_amd64.tar.gz -C /tmp/ibm_cloud_cli
export PATH=${PATH}:/tmp/ibm_cloud_cli/Bluemix_CLI/bin
mkdir /tmp/bin
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/bin/jq && chmod +x /tmp/bin/jq
export PATH=$PATH:/tmp/bin

# IBM cloud login
ibmcloud config --check-version=false
echo | ibmcloud login --apikey @"/etc/sno-power-credentials/.powercreds" --no-region

# Installing required ibmcloud plugins
echo "$(date) Installing required ibmcloud plugins"
ibmcloud plugin install -f power-iaas
ibmcloud plugin install -f cis

# Set target powervs and cis service instance
ibmcloud pi ws tg ${POWERVS_INSTANCE_CRN}
ibmcloud cis instance-set ${CIS_INSTANCE}

# Setting IBMCLOUD_TRACE to true to enable debug logs for pi and cis operations
export IBMCLOUD_TRACE=true

instance_id=$(ibmcloud pi ins ls --json | jq -r --arg serverName ${POWERVS_VSI_NAME} '.pvmInstances[] | select (.name == $serverName ) | .id')
if [ -n "${instance_id}" ]; then
  ibmcloud pi ins delete ${instance_id}
fi

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

mkdir -p ${BASTION_CI_SCRIPTS_DIR}
cat > ${BASTION_CI_SCRIPTS_DIR}/cleanup-sno.sh << EOF
#!/bin/bash

# This script tries to clean up things configured for SNO cluster by setup-sno.sh
# Run this script inside the bastion configured for pxe boot.
# Usage: ./cleanup-sno.sh \$CLUSTER_NAME.
#
# Sample usage: ./cleanup-sno.sh test-cluster
#


set -x
set +e

export CLUSTER_NAME=\$1
POWERVS_VSI_NAME="\${CLUSTER_NAME}-worker"

CONFIG_DIR="/tmp/\${CLUSTER_NAME}-config"
IMAGES_DIR="/var/lib/tftpboot/images/\${CLUSTER_NAME}"
WWW_DIR="/var/www/html/\${CLUSTER_NAME}"

LOCK_FILE="lockfile.lock"
(
flock -n 200 || exit 1;
echo "removing server host entry from dhcpd.conf"
/usr/bin/cp /etc/dhcp/dhcpd.conf.orig /etc/dhcp/dhcpd.conf
systemctl restart dhcpd;

echo "removing menuentry from grub.cfg"
/usr/bin/cp /var/lib/tftpboot/boot/grub2/grub.cfg.orig /var/lib/tftpboot/boot/grub2/grub.cfg
systemctl restart tftp;

echo "restarting tftp and dhcpd"
) 200>"\$LOCK_FILE"

rm -rf /tmp/\${CLUSTER_NAME}* \${IMAGES_DIR} \${WWW_DIR}

EOF

chmod +x ${BASTION_CI_SCRIPTS_DIR}/*.sh
ssh  "${SSH_OPTIONS[@]}" root@${BASTION} "mkdir -p ${BASTION_CI_SCRIPTS_DIR}/scripts; touch ${BASTION_CI_SCRIPTS_DIR}/scripts/lockfile.lock"
scp  "${SSH_OPTIONS[@]}" ${BASTION_CI_SCRIPTS_DIR}/* root@${BASTION}:${BASTION_CI_SCRIPTS_DIR}/scripts/.

# Run cleanup-sno.sh to clean up the things created on bastion for SNO node net boot
ssh "${SSH_OPTIONS[@]}" root@${BASTION} "cd ${BASTION_CI_SCRIPTS_DIR}/scripts && ./cleanup-sno.sh ${CLUSTER_NAME}"