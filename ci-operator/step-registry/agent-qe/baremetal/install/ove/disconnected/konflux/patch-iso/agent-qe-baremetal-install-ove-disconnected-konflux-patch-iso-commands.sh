#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

OVE_ISO_STORAGE_HOST=$(<"${CLUSTER_PROFILE_DIR}/ove_iso_storage_host")

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'TCPKeepAlive=yes'
  -o 'ServerAliveInterval=30'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
SSH_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")

CONTAINER_NAME="haproxy-$(<"${SHARED_DIR}"/cluster_name)"

timeout -s 9 10m ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" \
  "nsenter -n -t \"\$(podman inspect -f '{{ .State.Pid }}' \"${CONTAINER_NAME}\")\" \
   ssh -o StrictHostKeyChecking=no root@\"${OVE_ISO_STORAGE_HOST}\" patch_ove_iso_ignition_file.sh \
    \"${CLUSTER_NAME}.agent-ove.x86_64.iso\" \"${SSH_KEY}\""