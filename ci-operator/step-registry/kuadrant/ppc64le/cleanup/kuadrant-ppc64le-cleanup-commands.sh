#!/bin/bash

set -euo pipefail

echo "=== Cleaning up Kuadrant test components (best effort) ==="

# Kuadrant CR and test namespaces
oc delete kuadrant --all -n "${KUADRANT_NAMESPACE}" --ignore-not-found --timeout=60s || true
for ns in kuadrant kuadrant2 "${TOOLS_NAMESPACE}" istio-system istio-cni cert-manager-operator; do
  oc delete ns "${ns}" --ignore-not-found --timeout=120s || true
done

# Operator subscriptions installed for this test
# Capture each subscription's current CSV before deleting, then delete only those CSVs.
for entry in \
  "${KUADRANT_NAMESPACE}/${KUADRANT_SUBSCRIPTION_NAME}" \
  "cert-manager-operator/${CERT_MANAGER_SUBSCRIPTION_NAME}" \
  "openshift-operators/${OSSM_SUBSCRIPTION_NAME}"; do
  ns="${entry%%/*}"
  sub="${entry##*/}"
  csv="$(oc get subscription "${sub}" -n "${ns}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || true)"
  oc delete subscription "${sub}" -n "${ns}" --ignore-not-found --timeout=60s || true
  if [[ -n "${csv}" ]]; then
    oc delete csv "${csv}" -n "${ns}" --ignore-not-found --timeout=60s || true
  fi
done

# Kuadrant catalog source, if one was created by the install step
oc delete catalogsource kuadrant-operator-catalog -n "${KUADRANT_NAMESPACE}" --ignore-not-found || true

echo "=== Component cleanup complete ==="
