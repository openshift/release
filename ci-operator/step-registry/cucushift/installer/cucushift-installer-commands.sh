#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function get_clusterversion() {
    set -x
    clusterversion=$(oc get clusterversion/version)
    echo "Get cluster version:"
    echo "${clusterversion}"
    set +x
}

function get_nodes() {
    nodes_info=$(oc get nodes -owide)
    echo "Get nodes info:"
    echo "${nodes_info}"
}

function get_clusteroperators() {
    clusteroperators=$(oc get clusteroperators)
    echo "Get cluster operators:"
    echo "${clusteroperators}"
}

function get_networks_config() {
    clusterversion=$(oc get networks.config.openshift.io cluster -oyaml)
    echo "Get networks.config.openshift.io:"
    echo "${clusterversion}"
}

function get_networks_operator() {
    clusterversion=$(oc get networks.operator.openshift.io cluster -oyaml)
    echo "Get networks.operator.openshift.io:"
    echo "${clusterversion}"
}

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

set +e
get_clusterversion
get_nodes
get_clusteroperators
get_networks_config
get_networks_operator
set -e
