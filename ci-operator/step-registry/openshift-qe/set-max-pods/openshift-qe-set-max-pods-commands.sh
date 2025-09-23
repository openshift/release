#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MAX_PODS="${MAX_PODS:-250}"

echo "Setting maxPods to ${MAX_PODS} for worker nodes..."

cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: "set-max-pods"
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
  kubeletConfig:
    maxPods: ${MAX_PODS}
EOF

MCP_NAME=$(oc get mcp -l pools.operator.machineconfiguration.openshift.io/worker= -o jsonpath='{.items[*].metadata.name}')
if [[ -z "$MCP_NAME" ]]; then
  echo "Error: Could not find a MachineConfigPool with the 'worker' role."
  exit 1
fi

echo "Waiting for cluster to stabilize after applying KubeletConfig..."
oc adm wait-for-stable-cluster
echo "✅ Successfully configured maxPods=${MAX_PODS} on MachineConfigPool: ${MCP_NAME}"
