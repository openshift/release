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

echo "Waiting for clusteroperators to be ready"
export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig

until \
  oc wait clusterversion/version --for='condition=Available=True' > /dev/null;  do
    echo "$(date --rfc-3339=seconds) Cluster Operators not yet ready"
    oc get clusteroperators 2>/dev/null || true
    sleep 1s
done

if [[ -n ${MCE} ]] ; then
    echo "Waiting for ManagedCluster to be ready"
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
    until \
    oc wait managedcluster ${CLUSTER_NAME} --for='condition=ManagedClusterJoined' >/dev/null && \
    oc wait managedcluster ${CLUSTER_NAME} --for='condition=ManagedClusterConditionAvailable' >/dev/null && \
    oc wait managedcluster ${CLUSTER_NAME} --for='condition=HubAcceptedManagedCluster' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) ManagedCluster not yet ready"
    sleep 10s
    done
fi