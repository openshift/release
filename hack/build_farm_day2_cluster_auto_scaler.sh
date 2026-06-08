#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Illegal number of parameters"
  exit 1
fi

CLUSTER=$1
readonly CLUSTER

echo "Checking Cluster Auto-Sclaler on ${CLUSTER}"

if ! oc config get-contexts ${CLUSTER} > /dev/null ; then
  echo "found no context ${CLUSTER} in kubeconfig"
  exit 1
fi

if oc --context ${CLUSTER} get clusterautoscaler default > /dev/null ; then
    echo "Cluster Auto-Scaler is enabled already. Skipping"
    exit
fi

ID=$(ocm list cluster ${CLUSTER} --columns id --no-headers)
readonly ID

if [[ -z "${ID}" ]]; then
  echo "failed to find ID of the cluster ${CLUSTER}"
  exit 1
fi

echo "Configuring Cluster Auto-Sclaler on ${CLUSTER}"
ocm edit machinepool default --min-replicas=${MIN_REPLICAS:-2} --max-replicas=${MAX_REPLICAS:-50} -c ${CLUSTER}
