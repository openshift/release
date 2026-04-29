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

# Create a simple script to update the networking section using sed and awk
# This avoids dependency on yaml module
echo "Creating backup of original install-config.yaml..."
cp "${CONFIG}" "${CONFIG}.backup"

echo "Updating networking section in install-config.yaml..."

# Remove existing networking section and add our custom one
# This is a more reliable approach than trying to merge YAML without dependencies
awk '
BEGIN { in_networking = 0; print_networking = 0 }
/^networking:/ { 
    in_networking = 1
    print "networking:"
    print "  clusterNetwork:"
    print "  - cidr: '"${CLUSTER_NETWORK_CIDR}"'"
    print "    hostPrefix: '"${CLUSTER_NETWORK_HOST_PREFIX}"'"
    print "  serviceNetwork:"
    print "  - '"${SERVICE_NETWORK_CIDR}"'"
    print "  machineNetwork:"
    print "  - cidr: '"${MACHINE_NETWORK_CIDR}"'"
    print "  networkType: '"${NETWORK_TYPE}"'"
    print_networking = 1
    next
}
/^[a-zA-Z]/ && in_networking && !/^  / {
    in_networking = 0
}
!in_networking || /^  / && in_networking && print_networking {
    if (!in_networking) print $0
}
!in_networking && !print_networking {
    print $0
}
' "${CONFIG}.backup" > "${CONFIG}"

# If no networking section existed, add it at the end
if ! grep -q "^networking:" "${CONFIG}"; then
    echo "" >> "${CONFIG}"
    echo "networking:" >> "${CONFIG}"
    echo "  clusterNetwork:" >> "${CONFIG}"
    echo "  - cidr: ${CLUSTER_NETWORK_CIDR}" >> "${CONFIG}"
    echo "    hostPrefix: ${CLUSTER_NETWORK_HOST_PREFIX}" >> "${CONFIG}"
    echo "  serviceNetwork:" >> "${CONFIG}"
    echo "  - ${SERVICE_NETWORK_CIDR}" >> "${CONFIG}"
    echo "  machineNetwork:" >> "${CONFIG}"
    echo "  - cidr: ${MACHINE_NETWORK_CIDR}" >> "${CONFIG}"
    echo "  networkType: ${NETWORK_TYPE}" >> "${CONFIG}"
fi

echo "Updated install-config.yaml with custom network configuration:"
grep -A 10 "^networking:" "${CONFIG}" || echo "Failed to find networking section"