#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi
function wait_for_sriov_pods() {
    # Wait up to 15 minutes for SNO to be installed
    for _ in $(seq 1 15); do
        SNO_REPLICAS=$(oc get Deployment/sriov-network-operator -n openshift-sriov-network-operator -o jsonpath='{.status.readyReplicas}' || true)
        if [ "${SNO_REPLICAS}" == "1" ]; then
            FOUND_SNO=1
            break
        fi
        echo "Waiting for sriov-network-operator to be installed"
        sleep 60
    done

    if [ -n "${FOUND_SNO:-}" ] ; then
        # Wait for the pods to be started from the operator
        for _ in $(seq 1 8); do
            NOT_RUNNING_PODS=$(oc get pods --no-headers -n openshift-sriov-network-operator -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | grep false | wc -l || true)
            if [ "${NOT_RUNNING_PODS}" == "0" ]; then
                OPERATOR_READY=true
                break
            fi
            echo "Waiting for sriov-network-operator pods to be started and running"
            sleep 30
        done
        if [ -n "${OPERATOR_READY:-}" ] ; then
            echo "sriov-network-operator pods were installed successfully"
        else
            echo "sriov-network-operator pods were not installed after 4 minutes"
            oc get pods -n openshift-sriov-network-operator
            exit 1
        fi
    else
        echo "sriov-network-operator was not installed after 15 minutes"
        exit 1
    fi
}

function wait_for_sriov_network_node_state() {
    # Wait up to 5 minutes for SriovNetworkNodeState to be succeeded
    for _ in $(seq 1 10); do
        NODES_READY=$(oc get SriovNetworkNodeState --no-headers -n openshift-sriov-network-operator -o jsonpath='{.items[*].status.syncStatus}' | grep Succeeded | wc -l || true)
        if [ "${NODES_READY}" == "1" ]; then
            FOUND_NODE=1
            break
        fi
        echo "Waiting for SriovNetworkNodeState to be succeeded"
        sleep 30
    done

    if [ ! -n "${FOUND_NODE:-}" ] ; then
        echo "SriovNetworkNodeState is not succeeded after 5 minutes"
        oc get SriovNetworkNodeState -n openshift-sriov-network-operator -o yaml
        exit 1
    fi
}

SNO_NAMESPACE=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-sriov-network-operator
  annotations:
    workload.openshift.io/allowed: management
EOF
)
echo "Created \"$SNO_NAMESPACE\" Namespace"
SNO_OPERATORGROUP=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sriov-network-operators
  namespace: openshift-sriov-network-operator
spec:
  targetNamespaces:
  - openshift-sriov-network-operator
EOF
)
echo "Created \"$SNO_OPERATORGROUP\" OperatorGroup"
SNO_SUBSCRIPTION=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sriov-network-operator-subscription
  namespace: openshift-sriov-network-operator
spec:
  channel: stable
  name: sriov-network-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
)
echo "Created \"$SNO_SUBSCRIPTION\" Subscription"

# Wait up to 15 minutes for SNO to be installed
for _ in $(seq 1 90); do
    SNO_CSV=$(oc -n "${SNO_NAMESPACE}" get subscription "${SNO_SUBSCRIPTION}" -o jsonpath='{.status.installedCSV}' || true)
    if [ -n "$SNO_CSV" ]; then
        if [[ "$(oc -n "${SNO_NAMESPACE}" get csv "${SNO_CSV}" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            FOUND_SNO=1
            break
        fi
    fi
    echo "Waiting for sriov-network-operator to be installed"
    sleep 10
done

if [ -n "${FOUND_SNO:-}" ] ; then
    wait_for_sriov_pods
    wait_for_sriov_network_node_state
    echo "sriov-network-operator was installed successfully"
else
    echo "sriov-network-operator was not installed after 15 minutes"
    exit 1
fi
