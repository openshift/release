#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Waiting for cluster API to become reachable..."
for i in $(seq 1 "${API_WAIT_RETRIES}"); do
    if oc get --raw=/version &>/dev/null; then
        echo "Cluster API is reachable."
        exit 0
    fi
    echo "  Attempt ${i}/${API_WAIT_RETRIES}: API not reachable, retrying in ${API_WAIT_DELAY}s..."
    sleep "${API_WAIT_DELAY}"
done
echo "ERROR: Cluster API not reachable after $((API_WAIT_RETRIES * API_WAIT_DELAY))s"
exit 1
