#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

# Network configuration from environment variables
CLUSTER_NETWORK_CIDR="${CLUSTER_NETWORK_CIDR:-10.128.0.0/20}"
CLUSTER_NETWORK_HOST_PREFIX="${CLUSTER_NETWORK_HOST_PREFIX:-23}"
SERVICE_NETWORK_CIDR="${SERVICE_NETWORK_CIDR:-172.30.0.0/16}"
MACHINE_NETWORK_CIDR="${MACHINE_NETWORK_CIDR:-10.0.0.0/16}"
NETWORK_TYPE="${NETWORK_TYPE:-OVNKubernetes}"

echo "Configuring custom network settings for large scale test"
echo "  Cluster Network CIDR: ${CLUSTER_NETWORK_CIDR}"
echo "  Host Prefix: ${CLUSTER_NETWORK_HOST_PREFIX}"
echo "  Service Network CIDR: ${SERVICE_NETWORK_CIDR}"
echo "  Machine Network CIDR: ${MACHINE_NETWORK_CIDR}"
echo "  Network Type: ${NETWORK_TYPE}"

# Create the network configuration patch
cat > /tmp/network-patch.yaml << EOF
networking:
  clusterNetwork:
  - cidr: ${CLUSTER_NETWORK_CIDR}
    hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}
  serviceNetwork:
  - ${SERVICE_NETWORK_CIDR}
  machineNetwork:
  - cidr: ${MACHINE_NETWORK_CIDR}
  networkType: ${NETWORK_TYPE}
EOF

echo "Applying network patch to install-config.yaml"
yq eval-all '. as $item ireduce ({}; . * $item)' "${CONFIG}" /tmp/network-patch.yaml > /tmp/install-config-patched.yaml
cp /tmp/install-config-patched.yaml "${CONFIG}"

echo "Updated install-config.yaml with custom network configuration:"
yq eval '.networking' "${CONFIG}"