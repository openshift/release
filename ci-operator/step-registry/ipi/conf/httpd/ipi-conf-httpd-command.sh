#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

http_path="/var/www/html/"
vsphere_rhcos_image_location=$(openshift-install coreos print-stream-json | jq -r .architectures.x86_64.artifacts.vmware.formats.ova.disk.location)
vsphere_rhcos_image=`basename ${vsphere_rhcos_image_location}`

ls -lrt ${SSH_PRIV_KEY_PATH}

SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")
chmod 600 ${SSH_PRIV_KEY_PATH}
ls -lrt ${SSH_PRIV_KEY_PATH}

ssh -i "${SSH_PRIV_KEY_PATH}" -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no  ${BASTION_SSH_USER}@${BASTION_IP}  "sudo rm -rf ${http_path}${vsphere_rhcos_image} && sudo curl -Lk -o '${http_path}/${vsphere_rhcos_image}' '${vsphere_rhcos_image_location}'"

CONFIG="${SHARED_DIR}/install-config.yaml"
/tmp/yq -i '.platform.vsphere.clusterOSImage="http://${BASTION_IP}:80/${vsphere_rhcos_image}"' "${SHARED_DIR}/install-config.yaml"

status=$?
if [ X"$status" == X"0" ]; then
  echo "${vsphere_rhcos_image}"
else
  exit $status
fi

