#!/usr/bin/env bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"

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

firewall::open_port() {
  echo "no-op for aws"
}

firewall::close_port() {
  echo "no-op for aws"
}

export -f firewall::open_port
export -f firewall::close_port

USHIFT_IP="${IP_ADDRESS}" USHIFT_USER=${HOST_USER} /microshift/e2e/main.sh run

cat << EOF >${ARTIFACT_DIR}/config.yaml
USHIFT_HOST: ${IP_ADDRESS}
USHIFT_USER: ${HOST_USER}
SSH_PRIV_KEY: ${CLUSTER_PROFILE_DIR}/ssh-privatekey
EOF

git clone https://github.com/pacevedom/microshift -b USHIFT-1119 /tmp/microshift
cd /tmp/microshift/test
OUTPUT_DIR=${ARTIFACT_DIR} RF_VARIABLES=${ARTIFACT_DIR}/config.yaml make setup all
