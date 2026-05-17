#!/bin/bash

set -o nounset
set -o pipefail

debug_done=/tmp/debug.done
END_TIME=$(date -d "+3 hours" +%s)

SSH_KEY="${CLUSTER_PROFILE_DIR}/packet-ssh-key"
SERVER_IP_FILE="${SHARED_DIR}/server-ip"

if [[ -f "${SERVER_IP_FILE}" ]]; then
    SERVER_IP=$(cat "${SERVER_IP_FILE}")
    SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_KEY} root@${SERVER_IP}"
else
    SSH_CMD="# ERROR: ${SERVER_IP_FILE} not found — ofcir-acquire may have failed"
fi

echo "######################################################"
echo "# OSAC Debug Wait — dev-scripts image (SSH available)"
echo "# SSH to baremetal: ${SSH_CMD}"
echo "# Exit early: touch ${debug_done}"
echo "######################################################"

while sleep 1m; do
    test -f "${debug_done}" && echo "debug.done found, exiting." && break

    now=$(date +%s)
    if [ ${END_TIME} -lt ${now} ]; then
        echo "Timeout reached, exiting."
        break
    fi

    echo "--- $(date) | Waiting... (touch ${debug_done} to exit) ---"
    echo "    SSH to server: ${SSH_CMD}"
done
