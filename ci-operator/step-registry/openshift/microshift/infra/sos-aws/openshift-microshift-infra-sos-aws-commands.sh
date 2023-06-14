#!/bin/bash

set -eux

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
NUM_VMS="$(cat ${SHARED_DIR}/num_vms)"

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

for (( i=0; i<$NUM_VMS; i++ ))
do
  USER="$(cat ${SHARED_DIR}/user_${i})"
  PORT="$(cat ${SHARED_DIR}/ssh_port_${i})"
  ssh "${USER}@${IP_ADDRESS}" -p "${PORT}" "sudo sos report --batch --all-logs --tmp-dir /tmp -p container,network,microshift -o logs && sudo chmod +r /tmp/sosreport*"
  scp -P "${PORT}" "${USER}@${IP_ADDRESS}":/tmp/sosreport* "${ARTIFACT_DIR}/${i}"
done
