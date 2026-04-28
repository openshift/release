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

# Allow test access to Prometheus web API (ports 9090, 9091)
oc apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-test-access-prometheus-cilium
  namespace: openshift-monitoring
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: prometheus
  ingress:
  - ports:
    - port: 9090
      protocol: TCP
    - port: 9091
      protocol: TCP
  policyTypes:
  - Ingress
EOF

# Allow test access to Thanos Querier (ports 9091, 9092)
oc apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-test-access-thanos-cilium
  namespace: openshift-monitoring
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: thanos-query
  ingress:
  - ports:
    - port: 9091
      protocol: TCP
    - port: 9092
      protocol: TCP
  policyTypes:
  - Ingress
EOF

# Allow test access to Alertmanager (ports 9093, 9094)
oc apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-test-access-alertmanager-cilium
  namespace: openshift-monitoring
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: alertmanager
  ingress:
  - ports:
    - port: 9093
      protocol: TCP
    - port: 9094
      protocol: TCP
  policyTypes:
  - Ingress
EOF

# Allow monitoring to scrape router metrics (port 1936)
oc apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-scrape-router-cilium
  namespace: openshift-ingress
spec:
  podSelector:
    matchLabels:
      ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: openshift-monitoring
    ports:
    - port: 1936
      protocol: TCP
  policyTypes:
  - Ingress
EOF

echo "Cilium NetworkPolicy workarounds applied successfully"
