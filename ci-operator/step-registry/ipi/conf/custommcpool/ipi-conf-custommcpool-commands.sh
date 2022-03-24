#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, can not continue."
	exit 0
fi

node_name=$(oc get nodes -l=node-role.kubernetes.io/worker="" -o="jsonpath={.items[0].metadata.name}")
oc label node "$node_name" "node-role.kubernetes.io/tuned="

# Create infra machineconfigpool
oc create -f - <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: tuned
  labels:
    "pools.operator.machineconfiguration.openshift.io/tuned": ""
    machineconfiguration.openshift.io/role: tuned
spec:
  machineConfigSelector:
    matchLabels:
      machineconfiguration.openshift.io/role: tuned
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/tuned: ""
EOF

