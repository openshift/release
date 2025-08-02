#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

GPU_TYPE=${GPU_COMPUTE_NODE_TYPE:-}
if [[ -z "${GPU_TYPE}" ]]; then
	echo "$(date -u --rfc-3339=seconds) - GPU_COMPUTE_NODE_TYPE unspecified, nothing to do." && exit 0
fi

GPU_REPLICAS=${GPU_COMPUTE_NODE_REPLICAS:-}
if [[ -z "${GPU_REPLICAS}" ]]; then
	echo "$(date -u --rfc-3339=seconds) - GPU_COMPUTE_NODE_REPLICAS unspecified, nothing to do." && exit 0
fi
if [ "${GPU_REPLICAS}" -le 0 ]; then
    echo "$(date -u --rfc-3339=seconds) - GPU_COMPUTE_NODE_REPLICAS=$GPU_REPLICAS, nothing to do." && exit 0
fi
if [ "${GPU_REPLICAS}" -ge 1 ]; then
    # for now, we don't allow more than 1 gpu node to prevent runaway situation
    echo "$(date -u --rfc-3339=seconds) - GPU_COMPUTE_NODE_REPLICAS=$GPU_REPLICAS, forcing it to 1."
    GPU_REPLICAS=1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
echo "$(date -u --rfc-3339=seconds) - adding $GPU_REPLICAS gpu node(s) of type: \"$GPU_TYPE\" to config: $CONFIG"

echo "$(date -u --rfc-3339=seconds) - current configuration for 'compute' config: $CONFIG."
yq-v4 '.compute' -o yaml ${CONFIG}

gpureplicas=$GPU_REPLICAS yq-v4 e '(.compute | .[] | select(.name == "worker")).replicas = env(gpureplicas)' -i ${CONFIG}
gputype="$GPU_TYPE" yq-v4 e '(.compute | .[] | select(.name == "worker")).platform.gcp.type = strenv(gputype)' -i ${CONFIG}

echo "$(date -u --rfc-3339=seconds) - current configuration for 'compute' after adding the GPU nodes, config: $CONFIG."
yq-v4 '.compute' -o yaml ${CONFIG}
