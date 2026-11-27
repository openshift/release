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
CLUSTER_NAMESPACE_PREFIX="${E2E_HOSTED_CLUSTER_NAMESPACE:-${CLUSTER_NAMESPACE_PREFIX}}"
CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}

wait_for_ready_nodes="${HYPERSHIFT_WAIT_FOR_READY_NODES:-false}"
node_description="guest node"
if [[ "${wait_for_ready_nodes}" == "true" ]]; then
    node_description="Ready guest node"
fi

guest_nodes_match_replicas() {
    local desired_nodes actual_nodes
    desired_nodes="$(oc get nodepool "${CLUSTER_NAME}" -n "${CLUSTER_NAMESPACE_PREFIX}" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || return 1
    if [[ "${wait_for_ready_nodes}" == "true" ]]; then
        [[ "${desired_nodes}" =~ ^[1-9][0-9]*$ ]] || return 1
        actual_nodes="$(oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" get nodes --no-headers \
            -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' 2>/dev/null |
            awk '$2 == "True" { ready++ } END { if (ready == NR) print NR }')" || return 1
    else
        actual_nodes="$(oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" get nodes --no-headers 2>/dev/null | wc -l)" || return 1
    fi
    [[ -n "${desired_nodes}" && "${desired_nodes}" == "${actual_nodes}" ]]
}

echo "Waiting for the ${node_description} count to match NodePool replicas"
WAIT_TIMEOUT=$(($(date +%s) + 1800)) # 30 minutes
until guest_nodes_match_replicas; do
      if [[ $(date +%s) -ge ${WAIT_TIMEOUT} ]]; then
        echo "Timed out waiting for the ${node_description} count to match NodePool replicas after 30 minutes"
        exit 1
      fi
      echo "$(date --rfc-3339=seconds) The ${node_description} count does not match NodePool replicas. Retrying in 30 seconds."
      oc get vmi -n "${CLUSTER_NAMESPACE}" 2>/dev/null || true
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
    oc wait managedcluster "${CLUSTER_NAME}" --for='condition=ManagedClusterJoined' >/dev/null && \
    oc wait managedcluster "${CLUSTER_NAME}" --for='condition=ManagedClusterConditionAvailable' >/dev/null && \
    oc wait managedcluster "${CLUSTER_NAME}" --for='condition=HubAcceptedManagedCluster' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) ManagedCluster not yet ready"
    sleep 10s
    done
fi
