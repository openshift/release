#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-osimage.yaml.patch"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

http_path="/var/www/html/"
vsphere_rhcos_image_location=$(openshift-install coreos print-stream-json | jq -r .architectures.x86_64.artifacts.vmware.formats.ova.disk.location)
vsphere_rhcos_image=`basename ${vsphere_rhcos_image_location}`

SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")

#upload os image
ssh -i "${SSH_PRIV_KEY_PATH}" -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no  ${BASTION_SSH_USER}@${BASTION_IP}  "sudo rm -rf ${http_path}${vsphere_rhcos_image} && sudo curl -Lk -o '${http_path}/${vsphere_rhcos_image}' '${vsphere_rhcos_image_location}'"

#patch clusterOSimage into install-config.yaml
cat > "${PATCH}" << EOF
platform:
  vsphere:
    clusterOSImage: http://${BASTION_IP}:80/rhcos-412.86.202209302317-0-vmware.x86_64.ova
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

