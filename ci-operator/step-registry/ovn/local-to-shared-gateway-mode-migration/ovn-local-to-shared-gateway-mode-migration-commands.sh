#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Changing to shared gateway mode"
echo "-------------------"
oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\":{\"defaultNetwork\":{\"ovnKubernetesConfig\":{\"gatewayConfig\":{\"routingViaHost\":false}}}}}"

oc wait co network --for='condition=PROGRESSING=True' --timeout=30s
# Wait until the ovn-kubernetes pods are restarted
timeout 360s oc rollout status ds/ovnkube-node -n openshift-ovn-kubernetes
timeout 360s oc rollout status ds/ovnkube-master -n openshift-ovn-kubernetes

# ensure the gateway mode change was successful, if not no use proceeding with the test
mode=$(oc get Network.operator.openshift.io cluster -o template --template '{{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}}')
echo "Routing via host is set to ${mode}"
if [[ "${mode}" = false ]]; then
  echo "Overriding to OVN shared gateway mode was a success"
else
  echo "Overriding to OVN shared gateway mode was a faiure"
  exit 1
fi
