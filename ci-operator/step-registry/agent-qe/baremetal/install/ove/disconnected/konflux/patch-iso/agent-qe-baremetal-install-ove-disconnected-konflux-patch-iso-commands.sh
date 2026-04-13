#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

yq -r e -o=j -I=0 ".[0].host" "${SHARED_DIR}/hosts.yaml" >"${SHARED_DIR}"/host-id.txt

OVE_ISO_STORAGE_HOST=$(<"${SHARED_DIR}"/cluster_name).$(<"${CLUSTER_PROFILE_DIR}"/base_domain)
HOST_ID=$(<"${SHARED_DIR}"/host-id.txt)

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'TCPKeepAlive=yes'
  -o 'ServerAliveInterval=30'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  -p $((14000+"${HOST_ID}")))

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
SSH_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")

timeout -s 9 10m ssh "${SSHOPTS[@]}" root@access."${OVE_ISO_STORAGE_HOST}" sh patch_ove_iso_ignition_file.sh "${CLUSTER_NAME}.agent-ove.x86_64.iso" "${SSH_KEY}"