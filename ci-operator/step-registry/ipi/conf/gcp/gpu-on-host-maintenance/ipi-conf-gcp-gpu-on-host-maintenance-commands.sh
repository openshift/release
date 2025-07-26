#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${GPU_COMPUTE_NODE_TYPE}" ]]; then
	echo "$(date -u --rfc-3339=seconds) - GPU_COMPUTE_NODE_TYPE unspecified, nothing to do." && exit 0
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

echo "$(date -u --rfc-3339=seconds) - current configuration for 'compute' config: $CONFIG."
yq-v4 '.compute' -o yaml ${CONFIG}

# apply this to all gpu computing nodes
# TODO: should we also apply this to controlPlane gpu nodes?
yq-v4 -v '(.compute | .[] | select(.platform.gcp.type == "*gpu*") | .platform.gcp.onHostMaintenance) = "Terminate"' -i ${CONFIG}

echo "$(date -u --rfc-3339=seconds) - current configuration for 'compute' after adding the GPU nodes, config: $CONFIG."
yq-v4 '.compute' -o yaml ${CONFIG}
