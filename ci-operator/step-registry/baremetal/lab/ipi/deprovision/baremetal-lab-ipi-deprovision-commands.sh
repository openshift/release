#!/bin/bash

set -o nounset

[ -z "${PROVISIONING_HOST}" ] && { echo "\$PROVISIONING_HOST is not filled. Failing."; exit 1; }

echo "[INFO] Look for a bootstrap VM in the provisioning host and destroy it..."
LIBVIRT_DEFAULT_URI="qemu+ssh://root@${PROVISIONING_HOST}/system?keyfile=${CLUSTER_PROFILE_DIR}/ssh-key&no_verify=1&no_tty=1"
export LIBVIRT_DEFAULT_URI
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

# This destroys the bootstrap VM in the libvirt hypervisor
if virsh list --all --name | grep -q "${CLUSTER_NAME}"; then
  echo "[INFO] found the bootstrap VM. Destroying it..."
  NAME=$(virsh list --all --name | grep "${CLUSTER_NAME}")
  virsh destroy "${NAME}"
  virsh undefine "${NAME}" --remove-all-storage --nvram --managed-save --snapshots-metadata --wipe-storage
fi
