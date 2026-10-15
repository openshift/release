#!/bin/bash

set -euo pipefail

# Additive, test-scoped NetworkPolicy so the host-network TLS scanner can reach
# the pods it probes. tls-scanner-run scans with --all-pods, and components may
# ship restrictive ingress NetworkPolicies (e.g. ODH-ADR-Operator-0016) that
# otherwise deny the host-network scanner. This is deliberately NOT part of any
# product manifests; it is scoped to SCAN_NAMESPACE and torn down with it.
# https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/network_security/network-policy

# Fail loudly if the host-network group label resolves to no namespace: the
# policy would otherwise apply cleanly, match nothing, and silently drop the
# scanner again.
if [[ -z "$(oc get namespaces -l policy-group.network.openshift.io/host-network -o name)" ]]; then
  echo "ERROR: no namespace carries policy-group.network.openshift.io/host-network; host-network ingress rule would match nothing" >&2
  exit 1
fi

# Fail loudly if the workload under test is absent, otherwise the scan runs
# against an empty namespace and silently passes. When TLS_SCANNER_POD_SELECTOR
# is set, require at least one matching pod (callers use it to assert a specific
# component, e.g. an operand, is present); otherwise require any pod.
selector_args=()
if [[ -n "${TLS_SCANNER_POD_SELECTOR:-}" ]]; then
  selector_args=(-l "${TLS_SCANNER_POD_SELECTOR}")
fi
if [[ -z "$(oc -n "${SCAN_NAMESPACE}" get pods "${selector_args[@]}" -o name)" ]]; then
  echo "ERROR: no pods${TLS_SCANNER_POD_SELECTOR:+ matching '${TLS_SCANNER_POD_SELECTOR}'} found in ${SCAN_NAMESPACE}; nothing for the scanner to reach" >&2
  exit 1
fi

# Namespace-wide podSelector: tls-scanner-run probes all pods and ports, so admit
# host-network to every pod in the (ephemeral, single-component) scan namespace
# rather than guessing which ports it hits. Additive, so component policies still
# apply.
oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-tls-scanner
  namespace: ${SCAN_NAMESPACE}
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
