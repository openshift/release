#!/bin/bash

set -euo pipefail

# Target: management cluster -> guest cluster (Cluster A)
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: Management cluster kubeconfig not found at ${SHARED_DIR}/kubeconfig"
  exit 1
fi
if [[ ! -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
  echo "ERROR: Guest cluster (Cluster A) kubeconfig not found at ${SHARED_DIR}/nested_kubeconfig"
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "Saving management cluster kubeconfig"
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"

echo "Switching KUBECONFIG to guest cluster (Cluster A)"
cp "${SHARED_DIR}/nested_kubeconfig" "${SHARED_DIR}/kubeconfig"

echo "Verifying connectivity to guest cluster (Cluster A)"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc whoami
oc get nodes
