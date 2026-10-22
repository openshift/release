#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${SNAPSHOT}" ] && { echo "\$SNAPSHOT is not filled. Failing."; exit 1; }

OVE_ISO_STORAGE_HOST=$(<"${CLUSTER_PROFILE_DIR}/ove_iso_storage_host")
SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'TCPKeepAlive=yes'
  -o 'ServerAliveInterval=30'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

# SNAPSHOT example value passed by Konflux
# "quay.io/redhat-user-workloads/ocp-agent-based-installer-tenant/ove-ui-iso-4-21@sha256:c5c5269aec05dd1b16fedfd762b312f0f7b0858633d1f0850d17969f09e3df33"

echo "Konflux snapshot ID: ${SNAPSHOT}"

CONTAINER_NAME="haproxy-$(<"${SHARED_DIR}"/cluster_name)"

timeout -s 9 2h ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" \
  "nsenter -n -t \"\$(podman inspect -f '{{ .State.Pid }}' \"${CONTAINER_NAME}\")\" \
   ssh -o StrictHostKeyChecking=no root@\"${OVE_ISO_STORAGE_HOST}\" extract_ove_iso.sh \
    \"${SNAPSHOT}\" \"${CLUSTER_NAME}.agent-ove.x86_64.iso\""