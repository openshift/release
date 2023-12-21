#!/bin/bash
set -xeuo pipefail

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
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

device="/dev/xvdc"

if [[ "${EC2_INSTANCE_TYPE%.*}" =~ .*"g".* || "${EC2_INSTANCE_TYPE%.*}" =~ "t3".* ]]; then
  device="/dev/nvme1n1"
fi

ssh "${INSTANCE_PREFIX}" "lsblk ; sudo dnf install -y lvm2 && sudo pvcreate ${device} && sudo vgcreate rhel ${device}"
