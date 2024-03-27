#!/bin/bash

set -xeuo pipefail
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi
oc -n default delete clusters.cluster.x-k8s.io ${CLUSTER_NAME}
oc -n default delete secret rosa-creds-secret --ignore-not-found
oc -n default delete AWSClusterControllerIdentity default --ignore-not-found


