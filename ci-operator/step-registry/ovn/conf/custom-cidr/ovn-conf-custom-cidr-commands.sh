#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NETWORK_CIDR=${CLUSTER_NETWORK_CIDR:-10.128.0.0/20}
CLUSTER_NETWORK_HOST_PREFIX=${CLUSTER_NETWORK_HOST_PREFIX:-23}
SERVICE_NETWORK_CIDR=${SERVICE_NETWORK_CIDR:-172.30.0.0/16}

echo "default is to update cidr to 20 w/ hostPrefix of 23 so that max nodes num is 8"
echo "\nsee below for actual values used\n--------------------------------\n"

# Patch the existing networking section instead of appending a second "networking:" key
# (which would cause "key \"networking\" already set in map" when openshift-install reads the config).
CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-networking-custom-cidr.yaml.patch"
cat > "${PATCH}" << EOF
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: $CLUSTER_NETWORK_CIDR
    hostPrefix: $CLUSTER_NETWORK_HOST_PREFIX
  serviceNetwork:
  - $SERVICE_NETWORK_CIDR
EOF

if command -v yq-go &>/dev/null; then
  yq-go m -x -i "${CONFIG}" "${PATCH}"
else
  curl -L "https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
    -o /tmp/yq && chmod +x /tmp/yq
  /tmp/yq m -x -i "${CONFIG}" "${PATCH}"
fi

cat "${SHARED_DIR}/install-config.yaml"
