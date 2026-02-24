#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NETWORK_CIDR=${CLUSTER_NETWORK_CIDR:-10.217.0.0/16}
CLUSTER_NETWORK_HOST_PREFIX=${CLUSTER_NETWORK_HOST_PREFIX:-23}
SERVICE_NETWORK_CIDR=${SERVICE_NETWORK_CIDR:-172.30.0.0/16}
HYBRID_CLUSTER_NETWORK_CIDR=${HYBRID_CLUSTER_NETWORK_CIDR:-10.95.0.0/16}
HYBRID_CLUSTER_NETWORK_HOST_PREFIX=${HYBRID_CLUSTER_NETWORK_HOST_PREFIX:-23}

echo "clusterNetwork: $CLUSTER_NETWORK_CIDR/$CLUSTER_NETWORK_HOST_PREFIX"
echo "hybridClusterNetwork: $HYBRID_CLUSTER_NETWORK_CIDR/$HYBRID_CLUSTER_NETWORK_HOST_PREFIX"
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

# Create cluster-network manifest with clusterNetwork and hybridOverlayConfig for install
cat > "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  creationTimestamp: null
  name: cluster
spec:
  clusterNetwork:
  - cidr: $CLUSTER_NETWORK_CIDR
    hostPrefix: $CLUSTER_NETWORK_HOST_PREFIX
  externalIP:
    policy: {}
  networkType: OVNKubernetes
  serviceNetwork:
  - $SERVICE_NETWORK_CIDR
  defaultNetwork:
    type: OVNKubernetes
    ovnKubernetesConfig:
      hybridOverlayConfig:
        hybridClusterNetwork:
        - cidr: $HYBRID_CLUSTER_NETWORK_CIDR
          hostPrefix: $HYBRID_CLUSTER_NETWORK_HOST_PREFIX
EOF

cat "${SHARED_DIR}/install-config.yaml"
