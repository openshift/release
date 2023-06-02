#!/bin/bash

set -eux

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM


IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
USHIFT_USER="$(cat ${SHARED_DIR}/ushift_user)"
USHIFT_PORT="$(cat ${SHARED_DIR}/ushift_port)"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  User ${USHIFT_USER}
  Port ${USHIFT_PORT}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

scp -r "${IP_ADDRESS}":/var/log/pcp/pmlogger/* ${ARTIFACT_DIR}/
