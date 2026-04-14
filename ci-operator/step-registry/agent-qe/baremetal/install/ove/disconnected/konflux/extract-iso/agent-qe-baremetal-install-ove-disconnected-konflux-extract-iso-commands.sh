#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${SNAPSHOT}" ] && { echo "\$SNAPSHOT is not filled. Failing."; exit 1; }

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

# SNAPSHOT example value passed by Konflux
# "quay.io/redhat-user-workloads/ocp-agent-based-installer-tenant/ove-ui-iso-4-21@sha256:c5c5269aec05dd1b16fedfd762b312f0f7b0858633d1f0850d17969f09e3df33"

echo "Konflux snapshot ID: ${SNAPSHOT}"

timeout -s 9 2h ssh "${SSHOPTS[@]}" root@access."${OVE_ISO_STORAGE_HOST}" sh extract_ove_iso.sh "${SNAPSHOT}" "${CLUSTER_NAME}.agent-ove.x86_64.iso"