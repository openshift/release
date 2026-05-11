#!/bin/bash

set -o nounset
set -o pipefail

debug_done=/tmp/debug.done
END_TIME=$(date -d "+3 hours" +%s)

echo "######################################################"
echo "# OSAC Debug Wait — dev-scripts image (SSH available)"
echo "# SSH to baremetal: ssh -F /tmp/secret/ssh_config ci_machine"
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
    echo "    SSH to server: ssh -F /tmp/secret/ssh_config ci_machine"
done
