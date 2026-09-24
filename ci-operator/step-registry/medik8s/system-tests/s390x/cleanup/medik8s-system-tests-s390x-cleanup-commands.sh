#!/bin/bash

set -euo pipefail

echo "=== Cleaning up medik8s system-tests s390x OZ components (best effort) ==="

oc delete subscription --all -n "${INSTALL_NAMESPACE}" --ignore-not-found --timeout=120s || true
oc delete csv --all -n "${INSTALL_NAMESPACE}" --ignore-not-found --timeout=120s || true
oc delete operatorgroup --all -n "${INSTALL_NAMESPACE}" --ignore-not-found --timeout=60s || true
oc delete ns "${INSTALL_NAMESPACE}" --ignore-not-found --timeout=180s || true

if [[ -n "${CATALOG_SOURCE_NAME}" && "${CATALOG_SOURCE_NAME}" != "redhat-operators" ]]; then
  oc delete catalogsource "${CATALOG_SOURCE_NAME}" -n openshift-marketplace --ignore-not-found || true
fi
oc delete imagedigestmirrorset "${IDMS_NAME}" --ignore-not-found || true

echo "=== Component cleanup complete ==="
