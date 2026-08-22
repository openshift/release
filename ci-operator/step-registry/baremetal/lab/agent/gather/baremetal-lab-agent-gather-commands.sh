#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test -f "${SHARED_DIR}/install-status.txt"; then
  EXIT_CODE=$(cat "${SHARED_DIR}/install-status.txt")
  if [ "$EXIT_CODE" == 0 ]; then
    echo "Installation has been successfully completed, so there is no need to collect agent gather logs."
    exit "${EXIT_CODE}"
  fi
fi

if ! test -f "${SHARED_DIR}/host-id.txt"; then
    echo "Installation method is different from the ABI, so there is no need to execute this step."
    exit 0
fi

CONTAINER_NAME="haproxy-$(<"${SHARED_DIR}"/cluster_name)"
NODE_ZERO=$(yq -r ".[0].$( [[ ${ipv4_enabled:-false} == true ]] && echo ip || echo ipv6 )" "${SHARED_DIR}/hosts.yaml")
SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "Trying to gather agent logs on the host ${NODE_ZERO}"

if ssh "${SSHOPTS[@]}" root@"${AUX_HOST}" \
                         'nsenter -n -t "$(podman inspect -f '\''{{ .State.Pid }}'\'' "'"${CONTAINER_NAME}"'")" \
                          ssh -o StrictHostKeyChecking=no root@'"${NODE_ZERO}"' \
                          "agent-gather -O"' >"${ARTIFACT_DIR}"/agent-gather.tar.xz; then
  echo "Agent logs have been collected and published to the artifact directory as 'agent-gather.tar.xz'"
elif [ $? == 127 ]; then
  echo "Skip gathering agent logs, the agent-gather script is not present on the host ${NODE_ZERO}."
else
  echo "Failed to collect the agent logs."
fi