#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MCE=${MCE_VERSION:-""}
CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
if [[ -n ${MCE} ]] ; then
    CLUSTER_NAMESPACE_PREFIX=local-cluster
else
    CLUSTER_NAMESPACE_PREFIX=clusters
fi
CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}

echo "Waiting for nested cluster's node count to reach the desired replicas count in the NodePool"
until \
  [[ $(oc get nodepool ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE_PREFIX} -o jsonpath='{.spec.replicas}') \
    == $(oc --kubeconfig=${SHARED_DIR}/nested_kubeconfig get nodes --no-headers | wc -l) ]]; do
      echo "$(date --rfc-3339=seconds) Nested cluster's node count is not equal to the desired replicas in the NodePool. Retrying in 30 seconds."
      oc get vmi -n ${CLUSTER_NAMESPACE}
      sleep 30s
done
