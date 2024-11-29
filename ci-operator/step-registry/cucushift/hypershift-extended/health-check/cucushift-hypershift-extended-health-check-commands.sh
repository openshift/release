#!/bin/bash

set -e
set -u
set -o nounset
set -o errexit
set -o pipefail
set -x

# This function retrieves the cluster version using the 'oc' command and prints it.
function print_clusterversion {
    local clusterversion
    clusterversion=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
    echo "Cluster version: $clusterversion"
}

# Retry function that executes a given check function multiple times until it succeeds or reaches the maximum number of retries.
# Parameters:
#   - check_func: The function to be executed and checked for success.
# Returns:
#   - 0 if the check function succeeds within the maximum number of retries.
#   - 1 if the check function fails to succeed within the maximum number of retries.
# Usage example:
#   retry my_check_function
function retry() {
    local check_func=$1
    local max_retries=10
    local retry_delay=30
    local retries=0

    while (( retries < max_retries )); do
        if $check_func; then
            echo "All resources are in the expected state."
            return 0
        fi

        (( retries++ ))
        if (( retries < max_retries )); then
            echo "Retrying in $retry_delay seconds..."
            sleep $retry_delay
        fi
    done

    echo "Failed to get all resources in the expected state after $max_retries attempts."
    return 1
}

# This function checks the status of control plane pods in a HostedCluster.
# It first gets the name of the cluster using the "oc get hostedclusters" command.
# It then reads the output of "oc get pod" command in the corresponding HostedCluster namespace and checks if the status is "Running" or "Completed".
# If any pod is not in the expected state, it prints an error message and returns 1. Otherwise, it returns 0.
function check_control_plane_pod_status {
    HYPERSHIFT_NAMESPACE=$(oc get hostedclusters --ignore-not-found -A '-o=jsonpath={.items[0].metadata.namespace}')
    if [ -z "$HYPERSHIFT_NAMESPACE" ]; then
        echo "Could not find HostedCluster, which is not valid."
        return 1
    fi
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
    # ignore osd pods in for rosa hcp since it takes a very long time to recover for some reason.
    done < <(oc get pod --all-namespaces --no-headers | grep -v "azure-path-fix" | grep -v "osd-delete-backplane")
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

###Main###
export KUBECONFIG=${SHARED_DIR}/kubeconfig
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ -f "${SHARED_DIR}/cluster-type" ] ; then
    CLUSTER_TYPE=$(cat "${SHARED_DIR}/cluster-type")
    if [[ "$CLUSTER_TYPE" == "osd" ]] || [[ "$CLUSTER_TYPE" == "rosa" ]]; then
        echo "this cluster is ROSA-HyperShift"
        print_clusterversion
        check_node_status || exit 1
        retry check_cluster_operators || exit 1
        retry check_pod_status || exit 1
        exit 0
    fi
fi

echo "check mgmt cluster's HyperShift part"
if test -s "${SHARED_DIR}/mgmt_kubeconfig" ; then
  export KUBECONFIG=${SHARED_DIR}/mgmt_kubeconfig
  # Print clusterversion only if the management cluster is an OpenShift cluster
  if oc get ns openshift; then
      print_clusterversion
  fi
  retry check_control_plane_pod_status || exit 1
fi

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
echo "check guest cluster"
print_clusterversion
check_node_status || exit 1
retry check_cluster_operators || exit 1
retry check_pod_status || exit 1
oc get pod -A > "${ARTIFACT_DIR}/guest-pods"