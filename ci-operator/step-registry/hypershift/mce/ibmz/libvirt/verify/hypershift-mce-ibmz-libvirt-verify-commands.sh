#!/bin/bash

set -euo pipefail

for role in mgmt infra; do
  kubeconfig="${SHARED_DIR}/${role}/kubeconfig"
  if [[ ! -f "${kubeconfig}" ]]; then
    echo "Missing kubeconfig for ${role} cluster at ${kubeconfig}"
    exit 1
  fi
  echo "Verifying ${role} cluster using ${kubeconfig}"
  export KUBECONFIG="${kubeconfig}"
  oc get nodes
  oc get co
  if [[ -f "${SHARED_DIR}/${role}_cluster_name" ]]; then
    echo "${role} cluster name: $(cat "${SHARED_DIR}/${role}_cluster_name")"
  fi
done

echo "Both mgmt and infra clusters are reachable."
