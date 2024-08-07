#!/bin/bash
set -xeuo pipefail

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

cp /go/src/github.com/openshift/microshift/origin/skip.txt "${SHARED_DIR}/conformance-skip.txt"
cp "${SHARED_DIR}/conformance-skip.txt" "${ARTIFACT_DIR}/conformance-skip.txt"

# Disable workload partitioning for annotated pods to avoid cpu throttling
ssh "${INSTANCE_PREFIX}" "sudo sed -i 's/resources/#&/g' /etc/crio/crio.conf.d/11-microshift-ovn.conf"
ssh "${INSTANCE_PREFIX}" "sudo systemctl daemon-reload"
ssh "${INSTANCE_PREFIX}" "echo 1 | sudo microshift-cleanup-data --all"
ssh "${INSTANCE_PREFIX}" "sudo systemctl restart crio"
ssh "${INSTANCE_PREFIX}" "sudo systemctl start microshift"
