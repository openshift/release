#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

source "${SHARED_DIR}/ovn-utils.sh"

# make sure cluster is up and healthy after install and dump initial state. There are cases when not
# all operators are ready even after the install process has completed. Poll for another 15m to be
# sure and exit/fail if all operators are not healthy.
wait_for_operators_and_nodes 900
dump_cluster_state

# modify networks.operator.openshift.io with custom "internalJoinSubnet"
oc patch networks.operator.openshift.io cluster --type=merge -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipv4":{"internalTransitSwitchSubnet": "100.69.0.0/16"}}}}}'

# first wait for the network operator to move to Progressing=True
wait_for_operator_to_be_progressing network

# make sure all operators and nodes are good
wait_for_operators_and_nodes 300

# ensure the config change is reflected in the network.operator
internalTransitSwitchSubnet=$(oc get network.operator.openshift.io -o jsonpath='{.items[0].spec.defaultNetwork.ovnKubernetesConfig.ipv4.internalTransitSwitchSubnet}')
if [[ "$internalTransitSwitchSubnet" != "100.69.0.0/16" ]]; then
  echo "Error: internalTransitSwitchSubnet is misconfigured. Expected internalTransitSwitchSubnet of 100.69.0.0/16, but got:"
  oc get network.operator.openshift.io -o jsonpath='{.items[0].spec.defaultNetwork}'
  exit 1
fi

# the node annotation will be a specific IP address in the range of the configured subnet, so using wildcard
# matching on the last two octets
check_annotation_on_nodes "k8s.ovn.org/node-transit-switch-port-ifaddr" "ipv4" "100\.69\.[0-9]+\.[0-9]+/16"

# final state of the cluster
dump_cluster_state
