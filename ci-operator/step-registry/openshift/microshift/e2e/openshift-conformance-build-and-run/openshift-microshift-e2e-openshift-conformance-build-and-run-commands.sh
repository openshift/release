#!/usr/bin/env bash

set -xeuo pipefail

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"
DEST_DIR="/tmp/conformance"
ROOT_DIR="/home/${HOST_USER}/microshift"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

cat > /tmp/run.sh << EOF
set -xe
sudo cat /var/lib/microshift/resources/kubeadmin/kubeconfig > /tmp/kubeconfig
mkdir -p ${DEST_DIR}
if [ -f "${ROOT_DIR}/origin/run.sh" ]; then
    DEST_DIR="${DEST_DIR}" \
    KUBECONFIG="/tmp/kubeconfig" \
    "${ROOT_DIR}/origin/run.sh"
fi
EOF
chmod +x /tmp/run.sh

scp /tmp/run.sh "${INSTANCE_PREFIX}":/tmp
trap 'scp -r "${INSTANCE_PREFIX}":"${DEST_DIR}" "${ARTIFACT_DIR}"' EXIT
ssh "${INSTANCE_PREFIX}" "bash -x /tmp/run.sh" 
