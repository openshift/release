#!/bin/bash
set -euo pipefail

# Additive, test-scoped NetworkPolicy so the host-network TLS scanner can reach the component.
# https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/network_security/network-policy
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
