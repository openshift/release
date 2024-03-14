#!/bin/bash

set -xeuo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi
oc delete -n default clusters.cluster.x-k8s.io ${CLUSTER_NAME}
oc delete -n default secret rosa-creds-secret --ignore-not-found


