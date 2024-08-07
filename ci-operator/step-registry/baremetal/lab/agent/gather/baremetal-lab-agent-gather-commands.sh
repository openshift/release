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

if ! test -f "${SHARED_DIR}/node-zero-ip.txt"; then
    echo "Installation method is different from the ABI, so there is no need to execute this step."
    exit 0
fi

node_zero_ip=$(<"${SHARED_DIR}"/node-zero-ip.txt)
SSH_PORT=2222
SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "Trying to gather agent logs on the host ${node_zero_ip}"
ssh "${SSHOPTS[@]}" -N -L "${SSH_PORT}":"${node_zero_ip}":22 root@"${AUX_HOST}" &
SSH_PID=$!
# Wait for port forwarding to be ready
sleep 5

if ssh "${SSHOPTS[@]}" -t -p "${SSH_PORT}" "core@127.0.0.1" 'bash -c "agent-gather -O >/tmp/agent-gather.tar.xz"'; then
  scp "${SSHOPTS[@]}" -r -P "${SSH_PORT}" "core@127.0.0.1:/tmp/agent-gather.tar.xz" "${ARTIFACT_DIR}/agent-gather.tar.xz"
  echo "Agent logs have been collected and published to the artifact directory as 'agent-gather.tar.xz'"
elif [ $? == 127 ]; then
  echo "Skip gathering agent logs, the agent-gather script is not present on the host ${node_zero_ip}."
else
  echo "Failed to collect the agent logs."
fi
kill $SSH_PID