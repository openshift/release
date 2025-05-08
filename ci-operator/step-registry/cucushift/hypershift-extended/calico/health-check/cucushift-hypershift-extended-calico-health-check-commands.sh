#!/bin/bash

set -xeuo pipefail

if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
fi

# shellcheck disable=SC2016
timeout 30m bash -c 'until [[ $(oc get nodes --no-headers | wc -l) -eq "$HYPERSHIFT_NODE_COUNT" ]]; do sleep 15; done'

echo "Waiting for the guest cluster to be ready"
oc wait nodes --all --for=condition=Ready=true --timeout=15m

oc wait tigerastatus calico --for=condition=Available --timeout=30m || { oc get tigerastatus calico -oyaml; exit 1; }
oc wait tigerastatus apiserver --for=condition=Available --timeout=30m || { oc get tigerastatus apiserver -oyaml; exit 1; }
oc wait tigerastatus ippools --for=condition=Available --timeout=30m || { oc get tigerastatus ippools -oyaml; exit 1; }

oc wait clusteroperators --all --for=condition=Available=True --timeout=30m
oc wait clusteroperators --all --for=condition=Progressing=False --timeout=30m
oc wait clusteroperators --all --for=condition=Degraded=False --timeout=30m
oc wait clusterversion/version --for=condition=Available=True --timeout=30m
