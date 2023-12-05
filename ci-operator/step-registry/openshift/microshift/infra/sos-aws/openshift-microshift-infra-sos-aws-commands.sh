#!/bin/bash
set -xeuo pipefail

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

plugin_list="container,network"

ssh "${INSTANCE_PREFIX}" "sudo sos report --list-plugins | grep 'microshift.*inactive'" || plugin_list+=",microshift" 
ssh "${INSTANCE_PREFIX}" "sudo sos report --batch --all-logs --tmp-dir /tmp -p ${plugin_list} -o logs && sudo chmod +r /tmp/sosreport*"
scp "${INSTANCE_PREFIX}":/tmp/sosreport* "${ARTIFACT_DIR}"
