#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MAX_PODS="${MAX_PODS:-250}"

if [[ $TYPE == "sno" ]]; then
  MCP_NAME=$(oc get mcp -l pools.operator.machineconfiguration.openshift.io/master= -o jsonpath='{.items[*].metadata.name}')
else
  MCP_NAME=$(oc get mcp -l pools.operator.machineconfiguration.openshift.io/worker= -o jsonpath='{.items[*].metadata.name}')
fi

if [[ -z "$MCP_NAME" ]]; then
  echo "Error: Could not find a MachineConfigPool for the cluster"
  exit 1
fi

echo "Setting maxPods to ${MAX_PODS} for ${MCP_NAME} nodes..."

cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: "set-max-pods"
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${MCP_NAME}: ""
  kubeletConfig:
    maxPods: ${MAX_PODS}
EOF

echo "Waiting for cluster to stabilize after applying KubeletConfig..."
oc adm wait-for-stable-cluster
echo "✅ Successfully configured maxPods=${MAX_PODS} on MachineConfigPool: ${MCP_NAME}"
