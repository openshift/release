#!/bin/bash

set -euo pipefail

echo "=== Cleaning up ClusterResourceOverride s390x test components (best effort) ==="

oc delete clusterresourceoverride cluster -n "${CRO_NAMESPACE}" --ignore-not-found --timeout=60s || true
oc delete subscription "${CRO_SUBSCRIPTION_NAME}" -n "${CRO_NAMESPACE}" --ignore-not-found --timeout=60s || true
oc delete csv --all -n "${CRO_NAMESPACE}" --ignore-not-found --timeout=60s || true
oc delete operatorgroup --all -n "${CRO_NAMESPACE}" --ignore-not-found --timeout=60s || true
oc delete imagedigestmirrorset "${CRO_IDMS_NAME}" --ignore-not-found || true
oc delete ns "${CRO_NAMESPACE}" --ignore-not-found --timeout=180s || true

echo "=== Component cleanup complete ==="
