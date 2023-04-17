#!/bin/bash

set -e
set -u
set -o nounset
set -o errexit
set -o pipefail
set -x

# This function checks the status of control plane pods in a HostedCluster.
# It first gets the name of the cluster using the "oc get hostedclusters" command.
# It then reads the output of "oc get pod" command in the corresponding HostedCluster namespace and checks if the status is "Running" or "Completed".
# If any pod is not in the expected state, it prints an error message and returns 1. Otherwise, it returns 0.
function check_control_plane_pod_status {
    CLUSTER_NAME=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o=jsonpath='{.items[0].metadata.name}')
    while read -r pod _ status _; do
        if [[ "$status" != "Running" && "$status" != "Completed" ]]; then
            echo "Pod $pod in HostedCluster ControlPlane has status $status, which is not valid."
            return 1
        fi
    done < <(oc get pod -n "$HYPERSHIFT_NAMESPACE-$CLUSTER_NAME" --no-headers)
    echo "All pods are in the expected state."
    return 0
}

# This function checks the status of all pods in all namespaces.
# It reads the output of "oc get pod" command and checks if the status is "Running" or "Completed".
# If any pod is not in the expected state, it prints an error message and returns 1. Otherwise, it returns 0.
function check_pod_status {
    while read -r namespace pod _ status _; do
        if [[ "$status" != "Running" && "$status" != "Completed" ]]; then
            echo "Pod $pod in namespace $namespace has status $status, which is not valid."
            return 1
        fi
    done < <(oc get pod --all-namespaces --no-headers)
    echo "All pods are in the expected state."
    return 0
}

# This function checks the status of all cluster operators.
# It reads the output of "oc get clusteroperators" command and checks if the conditions are in the expected state.
# If any cluster operator is not in the expected state, it prints an error message and returns 1. Otherwise, it returns 0.
function check_cluster_operators {
    while read -r name _ available progressing degraded _; do
        if [[ "$available" != "True" || "$progressing" != "False" || "$degraded" != "False" ]]; then
            echo "Cluster operator $name is not in the expected state."
            return 1
        fi
    done < <(oc get clusteroperators --no-headers)
    echo "All cluster operators are in the expected state."
    return 0
}

# This function checks the status of all nodes.
# It reads the output of "oc get node" command and checks if the status is "Ready".
# If any node is not in the expected state, it prints an error message and returns 1. Otherwise, it returns 0.
function check_node_status {
    while read -r node status _ _ _; do
        if [[ "$status" != "Ready" ]]; then
            echo "Node $node has status $status, which is not valid."
            return 1
        fi
    done < <(oc get node --no-headers)
    echo "All nodes are in the expected state."
    return 0
}
echo "check mgmt cluster's HyperShift part"
export KUBECONFIG=${SHARED_DIR}/kubeconfig
if test -s "${SHARED_DIR}/mgmt_kubeconfig" ; then
  export KUBECONFIG=${SHARED_DIR}/mgmt_kubeconfig
fi
check_control_plane_pod_status || exit 1

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
echo "check guest cluster"
check_node_status || exit 1
check_cluster_operators || exit 1
check_pod_status || exit 1