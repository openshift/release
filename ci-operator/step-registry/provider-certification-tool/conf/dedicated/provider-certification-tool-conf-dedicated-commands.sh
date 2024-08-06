#!/bin/bash

#
# Setup the OPCT dedicated node to be used exclisvely for the
# aggregator server and workflow steps (plugin openshift-tests).
# The selector algorith tries to not use the nodes with prometheus
# server, heaviest workloads running in worker nodes, to prevent
# disruptions and total time to setup the environment.
#

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# TODO: move to 'opct adm setup-node'
# https://github.com/redhat-openshift-ecosystem/provider-certification-tool/blob/main/docs/user.md#prerequisites
# Taint one of the compute nodes
node=$(oc get nodes -l node-role.kubernetes.io/worker= -o name | shuf -n 1)
nodeName=$(basename "$node")
oc get node "$nodeName"
oc label node "$nodeName" node-role.kubernetes.io/tests=""
oc adm taint node "$nodeName" node-role.kubernetes.io/tests="":NoSchedule


if [ "${OPCT_RUN_MODE:-}" == "upgrade" ]; then
    cat << EOF | oc create -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: opct
spec:
  machineConfigSelector:
    matchExpressions:
    - key: machineconfiguration.openshift.io/role,
      operator: In,
      values: [worker,opct]
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/tests: ""
  paused: true
EOF

fi
