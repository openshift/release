#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${COMPUTE_NODE_TYPE}" ]]; then
	echo "$(date -u --rfc-3339=seconds) - COMPUTE_NODE_TYPE unspecified, nothing to do." && exit 0
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

if echo "${COMPUTE_NODE_TYPE}" | grep gpu; then
    yq-v4 -v '(.compute | .[] | select(.platform.gcp.type == "*gpu*") | .platform.gcp.onHostMaintenance) = "Terminate"' -i ${CONFIG}
else
    echo "$(date -u) - COMPUTE_NODE_TYPE=${COMPUTE_NODE_TYPE}, nothing to do."
fi
