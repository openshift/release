#!/bin/bash

set -o nounset

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "[INFO] Look for a bootstrap VM in the provisioning host and destroy it..."
LIBVIRT_DEFAULT_URI="qemu+ssh://root@${AUX_HOST}:$(sed 's/^[%]\?\([0-9]*\)[%]\?$/\1/' < "${CLUSTER_PROFILE_DIR}/provisioning-host-ssh-port-${architecture}")/system?keyfile=${CLUSTER_PROFILE_DIR}/ssh-key&no_verify=1&no_tty=1"
export LIBVIRT_DEFAULT_URI
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

# This destroys the bootstrap VM in the libvirt hypervisor
if virsh list --all --name | grep -q "${CLUSTER_NAME}"; then
  echo "[INFO] found the bootstrap VM. Destroying it..."
  NAME=$(virsh list --all --name | grep "${CLUSTER_NAME}")
  virsh destroy "${NAME}"
  virsh undefine "${NAME}" --remove-all-storage --nvram --managed-save --snapshots-metadata --wipe-storage
fi

timeout -s 9 2m ssh "${SSHOPTS[@]}" -p "$(sed 's/^[%]\?\([0-9]*\)[%]\?$/\1/' < "${CLUSTER_PROFILE_DIR}/provisioning-host-ssh-port-${architecture}")" "root@${AUX_HOST}" \
bash -s -- "${CLUSTER_NAME}" << 'EOF'
rm -rf /var/lib/libvirt/openshift-images/"${1}"-*-bootstrap
EOF
