#!/bin/bash

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


ssh "${HOST_USER}@${IP_ADDRESS}" "sudo cat /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig" >/tmp/kubeconfig

KUBECONFIG=/tmp/kubeconfig openshift-tests run "${TEST_SUITE}" -v 2 --provider=none -o "${ARTIFACT_DIR}/e2e.log" --junit-dir "${ARTIFACT_DIR}/junit"
