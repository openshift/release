#!/bin/bash

set -xeuo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
fi

# shellcheck disable=SC2016
timeout 30m bash -c 'until [[ $(oc get nodes --no-headers | wc -l) -eq "$HYPERSHIFT_NODE_COUNT" ]]; do sleep 15; done'

# Workaround for https://redhat.atlassian.net/browse/OCPBUGS-86033
# Calico hardcodes cniVersion 0.3.1 but Multus on OCP 4.22+ requires >= 0.4.0.
timeout 15m bash -c 'until oc -n calico-system get cm cni-config 2>/dev/null; do sleep 10; done'
oc -n calico-system rollout status ds/calico-node --timeout=15m || true

# Annotate the configmap to prevent the operator from reverting the patch.
oc annotate configmap cni-config -n calico-system unsupported.operator.tigera.io/ignore=true

oc -n calico-system get cm cni-config -o yaml | \
  sed 's/\\"cniVersion\\": \\"0.3.1\\"/\\"cniVersion\\": \\"0.4.0\\"/' | \
  oc apply -f -
oc -n calico-system rollout restart ds/calico-node
oc -n calico-system rollout status ds/calico-node --timeout=5m

oc wait tigerastatus calico --for=condition=Available --timeout=30m
oc wait tigerastatus apiserver --for=condition=Available --timeout=30m
oc wait tigerastatus ippools --for=condition=Available --timeout=30m

echo "Waiting for the guest cluster to be ready"
oc wait nodes --all --for=condition=Ready=true --timeout=15m

oc wait clusteroperators --all --for=condition=Available=True --timeout=30m
oc wait clusteroperators --all --for=condition=Progressing=False --timeout=30m
oc wait clusteroperators --all --for=condition=Degraded=False --timeout=30m
oc wait clusterversion/version --for=condition=Available=True --timeout=30m
