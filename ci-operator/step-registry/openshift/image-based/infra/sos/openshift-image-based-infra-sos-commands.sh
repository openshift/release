#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}/public_address")"
HOST_USER="$(cat "${SHARED_DIR}/ssh_user")"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

ssh "${SSHOPTS[@]}" "${INSTANCE_PREFIX}" <<'EOF'
  if ! hash sos ; then
    sudo touch /tmp/sosreport-command-does-not-exist
    exit 0
  fi

  plugin_list="container,network"

  if sudo sos report --batch --all-logs --tmp-dir /tmp -p ${plugin_list} -o logs ; then
    sudo chmod +r /tmp/sosreport-*
  else
    sudo touch /tmp/sosreport-command-failed
  fi
EOF
scp "${SSHOPTS[@]}" "${INSTANCE_PREFIX}":/tmp/sosreport-* "${ARTIFACT_DIR}" || true
