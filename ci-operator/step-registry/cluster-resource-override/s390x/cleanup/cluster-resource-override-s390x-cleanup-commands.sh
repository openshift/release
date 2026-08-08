#!/bin/bash

set -euo pipefail

echo "=== Cleaning up ClusterResourceOverride s390x test components (best effort) ==="

oc delete clusterresourceoverride cluster -n "${CRO_NAMESPACE}" --ignore-not-found --timeout=60s || true
oc delete subscription "${CRO_SUBSCRIPTION_NAME}" -n "${CRO_NAMESPACE}" --ignore-not-found --timeout=60s || true
oc delete csv --all -n "${CRO_NAMESPACE}" --ignore-not-found --timeout=60s || true
oc delete operatorgroup --all -n "${CRO_NAMESPACE}" --ignore-not-found --timeout=60s || true
oc delete imagedigestmirrorset "${CRO_IDMS_NAME}" --ignore-not-found || true
# Only delete custom catalogs we created; never remove stock redhat-operators.
if [[ -n "${CRO_CATALOG_SOURCE:-}" && "${CRO_CATALOG_SOURCE}" != "redhat-operators" && "${CRO_CATALOG_SOURCE}" != "certified-operators" && "${CRO_CATALOG_SOURCE}" != "community-operators" && "${CRO_CATALOG_SOURCE}" != "redhat-marketplace" ]]; then
  oc delete catalogsource "${CRO_CATALOG_SOURCE}" -n "${CRO_CATALOG_SOURCE_NAMESPACE:-openshift-marketplace}" --ignore-not-found || true
fi
oc delete ns "${CRO_NAMESPACE}" --ignore-not-found --timeout=180s || true

echo "=== Component cleanup complete ==="
