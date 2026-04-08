#!/bin/bash

set -euo pipefail

# Target: guest cluster (Cluster A) -> management cluster
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: Guest cluster (Cluster A) kubeconfig not found at ${SHARED_DIR}/kubeconfig"
  exit 1
fi
if [[ ! -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  echo "ERROR: Saved management cluster kubeconfig not found at ${SHARED_DIR}/mgmt_kubeconfig"
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "Saving guest cluster (Cluster A) kubeconfig"
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/guest_kubeconfig"

echo "Restoring management cluster kubeconfig"
cp "${SHARED_DIR}/mgmt_kubeconfig" "${SHARED_DIR}/kubeconfig"

echo "Verifying connectivity to management cluster"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc whoami
oc get nodes
