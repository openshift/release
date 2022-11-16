#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# https://github.com/redhat-openshift-ecosystem/provider-certification-tool/blob/main/docs/user.md#prerequisites
# Taint one of the compute nodes
node=$(oc get nodes -l node-role.kubernetes.io/worker= -o name | shuf -n 1)
nodeName=$(basename "$node")
oc get node "$nodeName"
oc label node "$nodeName" node-role.kubernetes.io/tests=""
oc adm taint node "$nodeName" node-role.kubernetes.io/tests="":NoSchedule

touch "${SHARED_DIR}/dedicated"
