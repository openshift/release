#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted common setup image registry command ************"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

until oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
do
  echo "$(date --rfc-3339=seconds) Failed to patch image registry configuration. Retrying..."
  sleep 15
done

echo "$(date -u --rfc-3339=seconds) - Image registry configuration patched"

until \
  oc wait --all=true clusteroperator --for='condition=Available=True' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Progressing=False' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Degraded=False' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    sleep 1s
done


echo "$(date --rfc-3339=seconds) Clusteroperators ready"
