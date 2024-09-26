#!/bin/bash

set -euo pipefail

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
oc patch networks.operator.openshift.io cluster --type=merge -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"ipsecConfig":{"mode":  "Full" }}}}}'
ipsec_config=$(oc get networks.operator.openshift.io cluster -o=jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode}')
echo "ipsec: $ipsec_config"
oc wait pods --for=condition=Ready -l app=ovnkube-node -n openshift-ovn-kubernetes --timeout=120s
oc wait pods --for=condition=Ready -l app=ovn-ipsec -n openshift-ovn-kubernetes --timeout=120s