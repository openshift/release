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
# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required to be able to SSH.
if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >>/etc/passwd
  else
    echo "/etc/passwd is not writeable, and user matching this uid is not found."
    exit 1
  fi
fi

node_zero_ip=$(<"${SHARED_DIR}"/node-zero-ip.txt)
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

echo "Trying to gather agent logs on the host ${node_zero_ip}"

if ssh -n -i "${SSH_PRIV_KEY_PATH}" -o 'ConnectTimeout=30' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' core@"${node_zero_ip}" agent-gather -O >"${ARTIFACT_DIR}"/agent-gather.tar.xz; then
  echo "Agent logs have been collected and published to the artifact directory as 'agent-gather.tar.xz'"
elif [ $? == 127 ]; then
  echo "Skip gathering agent logs, the agent-gather script is not present on the host ${node_zero_ip}."
else
  echo "Failed to collect the agent logs."
fi
