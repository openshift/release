#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Waiting for cluster API to become reachable..."
REQUIRED_CONSECUTIVE_SUCCESSES=5
CONSECUTIVE_SUCCESSES=0
for i in $(seq 1 "${API_WAIT_RETRIES}"); do
    if oc get --raw=/version &>/dev/null; then
        CONSECUTIVE_SUCCESSES=$((CONSECUTIVE_SUCCESSES + 1))
        if [[ "${CONSECUTIVE_SUCCESSES}" -ge "${REQUIRED_CONSECUTIVE_SUCCESSES}" ]]; then
            echo "Cluster API is reachable."
            exit 0
        fi
    else
        CONSECUTIVE_SUCCESSES=0
        echo "  Attempt ${i}/${API_WAIT_RETRIES}: API not reachable, retrying in ${API_WAIT_DELAY}s..."
    fi
    sleep "${API_WAIT_DELAY}"
done
echo "ERROR: Cluster API not reachable after $((API_WAIT_RETRIES * API_WAIT_DELAY))s"
exit 1
