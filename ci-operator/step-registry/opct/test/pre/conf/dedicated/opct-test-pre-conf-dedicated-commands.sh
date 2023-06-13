#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# https://github.com/redhat-openshift-ecosystem/provider-certification-tool/blob/main/docs/user.md#prerequisites
# Taint one of the compute nodes

OC_CMD="oc --insecure-skip-tls-verify"

if [[ "$OPCT_SETUP_DEDICATED" == "yes" ]] || [[ "$OPCT_SETUP_DEDICATED" == "true" ]]; then
  echo "Setting up dedicated node..."
  node=$($OC_CMD get nodes -l node-role.kubernetes.io/worker= -o name | shuf -n 1)
  nodeName=$(basename "$node")
  if [[ -z "${nodeName}" ]]; then
    echo "Unable to retrieve nodes with role node-role.kubernetes.io/worker"
    echo "Getting nodes:"
    $OC_CMD get nodes
    echo "Getting CSR:"
    $OC_CMD get csr
    exit 1
  fi
  $OC_CMD get node "$nodeName"
  $OC_CMD label node "$nodeName" node-role.kubernetes.io/tests=""
  $OC_CMD adm taint node "$nodeName" node-role.kubernetes.io/tests="":NoSchedule
  echo "dedicated node set"
fi

if [[ "$OPCT_SETUP_REGISTRY_LOCAL" == "yes" ]] || [[ "$OPCT_SETUP_DEDICATED" == "true" ]]; then
  echo "Setting up local image-registry..."
  $OC_CMD patch configs.imageregistry.operator.openshift.io cluster --type merge \
    --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
  echo "image registry patched, waiting 30s to continue"
  sleep 30
fi

if [ "${OPCT_RUN_MODE:-}" == "upgrade" ]; then
  echo "creating custom MCP for upgrade mode"
    cat << EOF | $OC_CMD create -f -
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