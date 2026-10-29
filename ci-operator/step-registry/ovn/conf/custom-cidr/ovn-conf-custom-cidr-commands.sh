#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${CLUSTER_NETWORK_CIDR:-}" ]]; then
  echo "CLUSTER_NETWORK_CIDR is not set; leaving the install configuration unchanged"
  exit 0
fi

CLUSTER_NETWORK_HOST_PREFIX=${CLUSTER_NETWORK_HOST_PREFIX:-23}
SERVICE_NETWORK_CIDR=${SERVICE_NETWORK_CIDR:-172.30.0.0/16}
CONFIG="${SHARED_DIR}/install-config.yaml"
CONFIG_PATCH="${SHARED_DIR}/install-config-ovn-custom-cidr.yaml.patch"

echo "configuring a custom cluster-network CIDR and hostPrefix"
echo "\nsee below for actual values used\n--------------------------------\n"

cat > "${CONFIG_PATCH}" << EOF
networking:
  clusterNetwork:
  - cidr: $CLUSTER_NETWORK_CIDR
    hostPrefix: $CLUSTER_NETWORK_HOST_PREFIX
  serviceNetwork:
  - $SERVICE_NETWORK_CIDR
EOF

if yq --version | grep -q 'version v4'; then
  yq eval-all --inplace 'select(fileIndex == 0) * select(fileIndex == 1)' "${CONFIG}" "${CONFIG_PATCH}"
else
  yq m -x -i "${CONFIG}" "${CONFIG_PATCH}"
fi

cat "${CONFIG}"
