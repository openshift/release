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


# Steps may not be used more than once in a test, so this block duplicates the behavior of wait-for-ssh for reboot tests.
timeout=300 # 5 minute wait.
>&2 echo "Polling ssh connectivity before proceeding.  Timeout=$timeout second"
start=$(date +"%s")
until ssh "${INSTANCE_PREFIX}" 'sudo systemctl start microshift';
do
  if (( $(date +"%s") - $start >= $timeout )); then
    echo "timed out out waiting for MicroShift to start" >&2
    exit 1
  fi
  echo "waiting for MicroShift to start"
  sleep 5
done
>&2 echo "It took $(( $(date +'%s') - start)) seconds to connect via ssh"

ssh "${INSTANCE_PREFIX}" "sudo cat /var/lib/microshift/resources/kubeadmin/${IP_ADDRESS}/kubeconfig" >/tmp/kubeconfig

if ! oc wait --kubeconfig=/tmp/kubeconfig --for=condition=Ready --timeout=120s pod/test-pod; then
  scp /microshift/validate-microshift/cluster-debug-info.sh "${INSTANCE_PREFIX}":~
  ssh "${INSTANCE_PREFIX}" 'export KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig; sudo -E ~/cluster-debug-info.sh'
  exit 1
fi
