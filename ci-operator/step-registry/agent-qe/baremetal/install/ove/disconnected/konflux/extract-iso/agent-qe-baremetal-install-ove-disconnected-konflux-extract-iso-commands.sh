#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${SNAPSHOT}" ] && { echo "\$SNAPSHOT is not filled. Failing."; exit 1; }

[ ! -f "${SHARED_DIR}/proxy-conf.sh" ] && { echo "Proxy conf file is not found. Failing."; exit 1; }

source "${SHARED_DIR}/proxy-conf.sh"
yq -r e -o=j -I=0 ".[0].host" "${SHARED_DIR}/hosts.yaml" >"${SHARED_DIR}"/host-id.txt

NODE_ZERO=$(<"${SHARED_DIR}"/cluster_name).$(<"${CLUSTER_PROFILE_DIR}"/base_domain)
HOST_ID=$(<"${SHARED_DIR}"/host-id.txt)
SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  -p $((14000+"${HOST_ID}")))

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

# SNAPSHOT example value passed by Konflux
# {"application":"ove-ui-4-21","components":[{"name":"ove-ui-iso-4-21","containerImage":"quay.io/redhat-user-workloads/ocp-agent-based-installer-tenant/ove-ui-iso-4-21@sha256:c5c5269aec05dd1b16fedfd762b312f0f7b0858633d1f0850d17969f09e3df33",
# "source":{"git":{"url":"https://github.com/openshift/agent-installer-utils","revision":"d5e584590355867515ff90bb9ccd2e9019073441"}}}],"artifacts":{}}


# Make the code compatible with runs triggered by Konflux and manual testing
KONFLUX_SNAPSHOT=$(echo ${SNAPSHOT} | jq -r '.components[].containerImage' )

echo "Konflux snapshot ID: ${KONFLUX_SNAPSHOT}"

timeout -s 9 10m ssh "${SSHOPTS[@]}" root@access."${NODE_ZERO}" extract_ove_iso.sh "${KONFLUX_SNAPSHOT}" "${CLUSTER_NAME}.agent-ove.x86_64.iso"

# APPLY MANOJ'S PATCH FOR BAREMETAL SERIAL CONSOLE

# Update the Ignition configuration to enable serial console access in the agent-interactive-console.service
# Change TTYPath=/dev/tty15 to TTYPath=/dev/ttyS0
# Remove ConditionPathExists=/dev/fb0
# Remove ExecStartPre=/usr/bin/chvt 15
# Add necessary kernel arguments to support serial console communication
# console=ttyS0,115200n8

timeout -s 9 10m ssh "${SSHOPTS[@]}" root@access."${NODE_ZERO}" patch_ove_iso.sh "${CLUSTER_NAME}.agent-ove.x86_64.iso"