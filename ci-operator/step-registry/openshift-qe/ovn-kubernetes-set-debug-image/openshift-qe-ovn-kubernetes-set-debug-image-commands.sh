#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [[ -z "${OVN_KUBERNETES_DEBUG_IMAGE}" ]]; then
  echo "ERROR: OVN_KUBERNETES_DEBUG_IMAGE is empty" >&2
  exit 1
fi

main() {
  oc patch clusterversion version --type=merge -p '{"spec":{"overrides":[{"group":"apps","kind":"Deployment","name":"network-operator","namespace":"openshift-network-operator","unmanaged":true}]}}'
  oc -n openshift-network-operator set env deployment/network-operator OVN_IMAGE="${OVN_KUBERNETES_DEBUG_IMAGE}"
  oc -n openshift-network-operator rollout status deployment/network-operator --timeout=10m
  wait_for_debug_image deployment/ovnkube-control-plane
  wait_for_debug_image daemonset/ovnkube-node
  oc -n openshift-ovn-kubernetes rollout status deployment/ovnkube-control-plane --timeout=30m
  oc -n openshift-ovn-kubernetes rollout status daemonset/ovnkube-node --timeout=60m
}

wait_for_debug_image() {
  local resource="$1"
  local images
  for _ in {1..60}; do
    images="$(oc -n openshift-ovn-kubernetes get "${resource}" -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null || true)"
    if [[ "${images}" == *"${OVN_KUBERNETES_DEBUG_IMAGE}"* ]]; then
      return 0
    fi
    sleep 10
  done
  echo "ERROR: ${OVN_KUBERNETES_DEBUG_IMAGE} was not observed in ${resource}" >&2
  return 1
}

main
