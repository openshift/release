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

echo "Waiting for ovn-ipsec pods ..."
start_time=$(date +"%s")
check_timeout=600
while true; do
  sleep 30
  res=$(oc get pods -l app=ovn-ipsec -n openshift-ovn-kubernetes --ignore-not-found)
  if [[ -n "${res}" ]]; then
    echo "find ovn-ipsec pods"
    break
  fi
  if (( $(date +"%s") - $start_time >= $check_timeout )); then
    echo "error: Timed out while waiting for ovn-ipsec pods"
    oc get networks.operator.openshift.io cluster > ${ARTIFACT_DIR}/hc-cluster-networks.yaml
    exit 1
  fi
done
oc wait pods --for=condition=Ready -l app=ovn-ipsec -n openshift-ovn-kubernetes --timeout=120s