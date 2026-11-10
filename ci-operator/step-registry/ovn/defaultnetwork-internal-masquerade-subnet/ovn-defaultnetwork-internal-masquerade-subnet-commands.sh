#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

ovnkube_node_pods=$(oc get pods -A -o name | grep ovnkube-node)

masq_route_found=0

while IFS= read -r pod; do
    # the grep here is hard-coded to 100.254.169 and needs to match what is used in the
    # step to configure internalMasqueradeSubnet which is done at install time
    if ! oc exec -nopenshift-ovn-kubernetes $pod ip route | grep "via 100.254.169"; then
      echo "Did not find the expected masquerade route 100.254.169 in the node routing table"
      oc exec -nopenshift-ovn-kubernetes $pod ip route
      masq_route_found=1
    fi
done < <(echo "$ovnkube_node_pods")

if [ $masq_route_found -eq 1 ]; then
  echo "At least one node did not have the expected masquerade route. exiting"
  exit 1
fi