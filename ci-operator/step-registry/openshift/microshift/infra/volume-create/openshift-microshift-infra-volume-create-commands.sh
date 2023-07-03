#!/bin/bash

set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  User ${HOST_USER}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

cat > "${HOME}"/volume-create.sh <<"EOF"
#!/bin/bash
set -xeuo pipefail

sudo dnf install -y lvm2 jq
pv_location=\$(sudo lsblk -Jd | jq -r '.blockdevices[] | select(.size == "200G") | "/dev/\(.name)"')

sudo pvcreate "\$pv_location"
sudo vgcreate rhel "\$pv_location"
sudo lvcreate -L 10G --thinpool thin rhel
EOF

chmod +x "${HOME}"/volume-create.sh

scp "${HOME}"/volume-create.sh "${INSTANCE_PREFIX}":~/volume-create.sh
ssh "${INSTANCE_PREFIX}" "/home/${HOST_USER}/volume-create.sh"
