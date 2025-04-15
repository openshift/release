#!/bin/bash

set -euo pipefail
set -o nounset
set -o errexit
set -o pipesfail

# Create KubeletConfig
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
    maxPods: 2550
EOF

MCP_NAME=$(oc get machineconfigpools -o jsonpath='{.items[?(@.metadata.labels."pools.operator.machineconfiguration.openshift.io/role" == "worker")].metadata.name}')
if [[ -z "$MCP_NAME" ]]; then
  echo "Error: Could not find a MachineConfigPool with the 'worker' role."
  exit 1
fi

oc adm wait-for-stable-cluster

echo "Successfully configured maxPods on worker nodes."
