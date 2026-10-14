#!/bin/bash
set -euo pipefail

# Additive, test-scoped NetworkPolicy so the host-network TLS scanner can reach the component.
# https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/network_security/network-policy

# Fail loudly if the host-network group label does not resolve to a namespace:
# the policy would otherwise apply cleanly, match nothing, and silently drop the
# scanner again.
host_net_ns=$(oc get namespaces -l policy-group.network.openshift.io/host-network -o name)
if [[ -z "$host_net_ns" ]]; then
  echo "ERROR: no namespace carries policy-group.network.openshift.io/host-network; host-network ingress rule would match nothing" >&2
  exit 1
fi

oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-tls-scanner-metrics
  namespace: ${OPERATOR_NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          policy-group.network.openshift.io/host-network: ""
EOF
