#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# collect logs from mirror registry server here
if [ -f "${SHARED_DIR}/bastion_private_address" ]; then
  BASTION_IP="$(< "${SHARED_DIR}/bastion_private_address")"
  BASTION_SSH_USER="$(< "${SHARED_DIR}/bastion_ssh_user" )"
  SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

  if ! whoami &> /dev/null; then
    if [ -w /etc/passwd ]; then
      echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    fi
  fi

  declare -a registry_ports=("5000" "6001" "6002")

  for port in "${registry_ports[@]}"; do
    ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no ${BASTION_SSH_USER}@"${BASTION_IP}" \
        "sudo journalctl -u poc-registry-${port}" > "${ARTIFACT_DIR}/poc-registry-${port}.service"
  done
fi
