#!/bin/bash

set -euo pipefail
set -o nounset
set -o errexit
set -o pipesfail

MAX_PODS=500 # Set the desired maxPods value

CLUSTER_NETWORK_CIDR=${CLUSTER_NETWORK_CIDR:-10.128.0.0/20}
CLUSTER_NETWORK_HOST_PREFIX=${CLUSTER_NETWORK_HOST_PREFIX:-23}

echo "default is to update cidr to 20 w/ hostPrefix of 23 so that max nodes num is 8"
echo "\nsee below for actual values used\n--------------------------------\n"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: $CLUSTER_NETWORK_CIDR
    hostPrefix: $CLUSTER_NETWORK_HOST_PREFIX
EOF

cat "${SHARED_DIR}/install-config.yaml"

# Patch Nodes
NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')

for NODE in $NODES; do
  oc patch node "$NODE" --type=merge -p "{\"spec\":{\"podCIDRConfig\":{\"maxPods\": $MAX_PODS}}}"
done

# Create KubeletConfig
cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: increased-max-pods
spec:
  kubeletConfig:
    maxPods: $MAX_PODS
EOF

# Apply KubeletConfig to MachineConfigPool
MCP_NAME=$(oc get machineconfigpools -o jsonpath='{.items[0].metadata.name}')
oc patch machineconfigpool "$MCP_NAME" --type=merge -p '{"spec":{"configuration":{"kubeletConfig":{"name":"increased-max-pods"}}}}'
