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

API_NODE_ZERO="api.$(<"${SHARED_DIR}"/cluster_name).$(<"${CLUSTER_PROFILE_DIR}"/base_domain)"
HOST_ID=$(<"${SHARED_DIR}"/host-id.txt)
SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key"
  -p $((13000+"${HOST_ID}")))

echo "Trying to gather agent logs on the host ${HOST_ID}"

if ssh "${SSHOPTS[@]}" core@"${API_NODE_ZERO}" agent-gather -O >"${ARTIFACT_DIR}"/agent-gather.tar.xz; then
  echo "Agent logs have been collected and published to the artifact directory as 'agent-gather.tar.xz'"
elif [ $? == 127 ]; then
  echo "Skip gathering agent logs, the agent-gather script is not present on the host ${HOST_ID}."
else
  echo "Failed to collect the agent logs."
fi