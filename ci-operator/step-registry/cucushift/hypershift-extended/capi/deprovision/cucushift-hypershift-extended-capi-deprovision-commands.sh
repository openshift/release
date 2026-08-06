#!/bin/bash

set -xeuo pipefail
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

if [[ -f "${SHARED_DIR}/cluster-name" ]]; then
  shared_cluster_name=$(cat ${SHARED_DIR}/cluster-name)
  if [[ -n "${shared_cluster_name}" ]]; then
    CLUSTER_NAME=${shared_cluster_name}
  fi
fi

if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "cluster name not found error, CLUSTER_NAME var is empty"
  exit 1
fi

oc -n default delete clusters.cluster.x-k8s.io ${CLUSTER_NAME} --ignore-not-found
oc -n default delete secret rosa-creds-secret --ignore-not-found
oc -n default delete AWSClusterControllerIdentity default --ignore-not-found


