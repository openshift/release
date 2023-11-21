#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

echo "Changing to shared gateway mode"
echo "-------------------"
oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\":{\"defaultNetwork\":{\"ovnKubernetesConfig\":{\"gatewayConfig\":{\"routingViaHost\":false}}}}}"

oc wait co network --for='condition=PROGRESSING=True' --timeout=60s
# Wait until the ovn-kubernetes pods are restarted
sample_node=$(oc get no -o jsonpath='{.items[0].metadata.name}')
sample_node_zone=$(oc get node "${sample_node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/zone-name}')
if [ "${sample_node}" = "${sample_node_zone}" ]; then
  echo "INFO: INTERCONNECT MODE"
  # FIXME: Increasing timeout to 15minutes for OVNK IC deployments (original value was 360seconds)
  # See https://issues.redhat.com/browse/OCPBUGS-16629 for details
  timeout 900s oc rollout status ds/ovnkube-node -n openshift-ovn-kubernetes
  timeout 900s oc rollout status deployment/ovnkube-control-plane -n openshift-ovn-kubernetes
else
  echo "INFO: LEGACY MODE"
  timeout 360s oc rollout status ds/ovnkube-node -n openshift-ovn-kubernetes
  timeout 360s oc rollout status ds/ovnkube-master -n openshift-ovn-kubernetes
fi
# ensure the gateway mode change was successful, if not no use proceeding with the test
mode=$(oc get Network.operator.openshift.io cluster -o template --template '{{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}}')
echo "Routing via host is set to ${mode}"
if [[ "${mode}" = false ]]; then
  echo "Overriding to OVN shared gateway mode was a success"
else
  echo "Overriding to OVN shared gateway mode was a faiure"
  exit 1
fi
