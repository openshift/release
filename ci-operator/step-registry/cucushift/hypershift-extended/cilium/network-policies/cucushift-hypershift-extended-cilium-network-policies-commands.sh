#!/bin/bash

set -euxo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
fi

echo "Applying additional NetworkPolicies for Cilium compatibility"
echo "OCP 4.22+ adds deny-all NetworkPolicies in openshift-monitoring and openshift-ingress."
echo "OVN handles these via the network.openshift.io/policy-group label, but Cilium does not."
echo "These policies restore the required traffic paths for conformance tests."

# Allow all ingress to openshift-monitoring so test pods can access
# Prometheus, Thanos Querier, and Alertmanager endpoints.
# The OCP 4.22 deny-all policy blocks this traffic under Cilium.
oc apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-ingress-cilium-workaround
  namespace: openshift-monitoring
spec:
  podSelector: {}
  ingress:
  - {}
  policyTypes:
  - Ingress
EOF

# Allow all ingress to openshift-ingress so monitoring can scrape
# router metrics and LB tests can reach ingress endpoints.
oc apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-all-ingress-cilium-workaround
  namespace: openshift-ingress
spec:
  podSelector: {}
  ingress:
  - {}
  policyTypes:
  - Ingress
EOF

echo "Cilium NetworkPolicy workarounds applied successfully"
