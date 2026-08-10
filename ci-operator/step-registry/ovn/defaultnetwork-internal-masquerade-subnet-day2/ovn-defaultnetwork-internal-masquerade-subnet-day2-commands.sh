#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

source "${SHARED_DIR}/ovn-utils.sh"

OVN_INTERNAL_MASQUERADE_SUBNET_DAY2="${OVN_INTERNAL_MASQUERADE_SUBNET_DAY2:-100.254.170.0/24}"
masq_route_grep=$(echo "${OVN_INTERNAL_MASQUERADE_SUBNET_DAY2%/*}" | cut -d. -f1-3)

# make sure cluster is up and healthy after install and dump initial state. There are cases when not
# all operators are ready even after the install process has completed. Poll for another 15m to be
# sure and exit/fail if all operators are not healthy.
wait_for_operators_and_nodes 900
dump_cluster_state

# modify networks.operator.openshift.io with custom "internalMasqueradeSubnet"
oc patch networks.operator.openshift.io cluster --type=merge -p "{\"spec\":{\"defaultNetwork\":{\"ovnKubernetesConfig\":{\"gatewayConfig\":{\"ipv4\":{\"internalMasqueradeSubnet\": \"${OVN_INTERNAL_MASQUERADE_SUBNET_DAY2}\"}}}}}}"

# first wait for the network operator to move to Progressing=True
wait_for_operator_to_be_progressing network

# make sure all operators and nodes are good
wait_for_operators_and_nodes 300

# ensure the config change is reflected in the network.operator
internalMasqueradeSubnet=$(oc get network.operator.openshift.io -o jsonpath='{.items[0].spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipv4.internalMasqueradeSubnet}')
if [[ "$internalMasqueradeSubnet" != "${OVN_INTERNAL_MASQUERADE_SUBNET_DAY2}" ]]; then
  echo "Error: internalMasqueradeSubnet is misconfigured. Expected internalMasqueradeSubnet of ${OVN_INTERNAL_MASQUERADE_SUBNET_DAY2}, but got:"
  oc get network.operator.openshift.io -o jsonpath='{.items[0].spec.defaultNetwork}'
  exit 1
fi

ovnkube_node_pods=$(oc get pods -A -o name | grep ovnkube-node)

masq_route_found=0

while IFS= read -r pod; do
    if ! oc exec -nopenshift-ovn-kubernetes "$pod" ip route | grep "via ${masq_route_grep}"; then
      echo "Did not find the expected masquerade route ${masq_route_grep} in the node routing table"
      oc exec -nopenshift-ovn-kubernetes "$pod" ip route
      masq_route_found=1
    fi
done < <(echo "$ovnkube_node_pods")

if [ $masq_route_found -eq 1 ]; then
  echo "At least one node did not have the expected masquerade route. exiting"
  exit 1
fi

# final state of the cluster
dump_cluster_state
