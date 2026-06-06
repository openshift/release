#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

debug_done=/tmp/debug.done
END_TIME=$(date -d "+3 hours" +%s)

echo "######################################################"
echo "# OSAC Debug Wait — dev-scripts image (SSH available)"
echo "# SSH to baremetal: ssh -i <CLUSTER_PROFILE_DIR>/packet-ssh-key root@<server-ip>"
echo "# server-ip is stored in SHARED_DIR/server-ip"
echo "# Exit early: touch ${debug_done}"
echo "######################################################"

while sleep 1m; do
    test -f "${debug_done}" && echo "debug.done found, exiting." && break

    now=$(date +%s)
    if [ "${END_TIME}" -lt "${now}" ]; then
        echo "Timeout reached, exiting."
        break
    fi

    echo "--- $(date) | Waiting... (touch ${debug_done} to exit) ---"
done
