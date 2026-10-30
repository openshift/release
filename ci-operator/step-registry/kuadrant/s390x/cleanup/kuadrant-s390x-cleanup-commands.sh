#!/bin/bash

set -euo pipefail

echo "=== Cleaning up Kuadrant test components (best effort) ==="

# Kuadrant CR and test namespaces
oc delete kuadrant --all -n "${KUADRANT_NAMESPACE}" --ignore-not-found --timeout=60s || true
for ns in kuadrant kuadrant2 tools istio-system istio-cni cert-manager-operator; do
  oc delete ns "${ns}" --ignore-not-found --timeout=120s || true
done

# Operator subscriptions installed for this test
for entry in \
  "${KUADRANT_NAMESPACE}/kuadrant-operator" \
  "cert-manager-operator/openshift-cert-manager-operator" \
  "openshift-operators/servicemeshoperator3"; do
  ns="${entry%%/*}"
  sub="${entry##*/}"
  oc delete subscription "${sub}" -n "${ns}" --ignore-not-found --timeout=60s || true
  oc delete csv --all -n "${ns}" --ignore-not-found --timeout=60s || true
done

# Kuadrant catalog source, if one was created by the install step
oc delete catalogsource kuadrant-operator-catalog -n "${KUADRANT_NAMESPACE}" --ignore-not-found || true

echo "=== Component cleanup complete ==="
