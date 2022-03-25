#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, can not continue."
	exit 0
fi
node_role=tuned
node_name=$(oc get nodes -l=node-role.kubernetes.io/worker="" -o="jsonpath={.items[0].metadata.name}")
oc label node "$node_name" "apply-mc-config=tuned"

oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${node_role}
  name: realtime-worker
spec:
  kernelType: realtime
EOF

# Create infra machineconfigpool
oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: ${node_role}
  labels:
    machineconfiguration.openshift.io/role: ${node_role}
spec:
  machineConfigSelector:
    matchLabels:
      machineconfiguration.openshift.io/role: ${node_role}
  nodeSelector:
    matchLabels:
      apply-mc-config: ${node_role}
EOF


echo "waiting for mcp/${node_role} condition=Updating timeout=5m"
oc wait mcp/${node_role} --for condition=Updating --timeout=5m

echo "waiting for mcp/${node_role} condition=Updated timeout=30m"
oc wait mcp/${node_role} --for condition=Updated --timeout=30m
