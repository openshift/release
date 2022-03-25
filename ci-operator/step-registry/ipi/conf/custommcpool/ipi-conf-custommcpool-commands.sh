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
oc label node "$node_name" "node-role.kubernetes.io/worker-rt="

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
    matchExpressions:
      - {key: machineconfiguration.openshift.io/role, operator: In, values: [worker,${node_role}]}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/worker-rt: ""
      node-role.kubernetes.io/worker: ""
EOF

