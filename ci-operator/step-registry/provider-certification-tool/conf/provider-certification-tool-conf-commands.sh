#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# https://github.com/redhat-openshift-ecosystem/provider-certification-tool/blob/main/docs/user.md#prerequisites
# Add another node to first MachineSet
compute=$(oc get machinesets -n openshift-machine-api --output=jsonpath='{.items[0].metadata.name}')
oc scale machineset/"${compute}" -n openshift-machine-api --replicas=4

# Wait for new machine and node to become ready
oc wait --for=jsonpath='{.status.readyReplicas}'=4 machineset/"${compute}" -n openshift-machine-api --timeout=10m
oc wait nodes --all --for=condition=Ready=true --timeout=10m

# Taint one of the Nodes in MachineSet
machine=$(oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset="${compute}" -o name | shuf -n 1)
node=$(basename "$machine")
oc get node "$node"
oc label node "$node" node-role.kubernetes.io/tests=""
oc adm taint node "$node" node-role.kubernetes.io/tests="":NoSchedule

# Ensure all Cluster Operators are ready
oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io --timeout=10m > /dev/null
oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=10m > /dev/null
oc wait --all --for=condition=Degraded=False clusteroperators.config.openshift.io --timeout=10m > /dev/null
