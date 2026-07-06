#!/bin/bash

set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

set -x

if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
fi

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1-2)
if [[ "$OCP_VERSION" != "4.22" && "$OCP_VERSION" != "5.0" ]]; then
    echo "OCP version ${OCP_VERSION}, skipping NetworkPolicy workarounds"
    exit 0
fi

echo "Waiting for CiliumNetworkPolicy CRD to be available..."
timeout 30m bash -c 'until oc get crd ciliumnetworkpolicies.cilium.io &>/dev/null; do sleep 10; done'

# Required for OCP 4.22: See https://redhat.atlassian.net/browse/OCPBUGS-85607
oc apply -f - <<'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dns-allow-kube-apiserver
  namespace: openshift-dns
spec:
  endpointSelector:
    matchLabels:
      dns.operator.openshift.io/daemonset-dns: default
  egress:
  - toEntities:
    - host
EOF

echo "Cilium NetworkPolicy workarounds applied successfully"
