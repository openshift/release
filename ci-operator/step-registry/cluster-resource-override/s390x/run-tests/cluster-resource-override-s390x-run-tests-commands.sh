#!/bin/bash

set -euo pipefail

echo "=== ClusterResourceOverride s390x placeholder test ==="
echo "Namespace: ${CRO_NAMESPACE}"

echo "=== Operator status ==="
oc get deployment,pods,csv,subscription -n "${CRO_NAMESPACE}" -o wide || true
oc get clusterresourceoverride -A -o wide || true

echo "=== Checking operator Deployment Available ==="
oc wait --for=condition=Available deployment/clusterresourceoverride-operator \
  -n "${CRO_NAMESPACE}" --timeout=300s

oc get deployment/clusterresourceoverride-operator -n "${CRO_NAMESPACE}" -o yaml \
  > "${ARTIFACT_DIR}/clusterresourceoverride-operator-deployment.yaml" || true
oc get csv -n "${CRO_NAMESPACE}" -o yaml \
  > "${ARTIFACT_DIR}/clusterresourceoverride-csv.yaml" || true

echo "=== Placeholder test passed (replace with real testsuite later) ==="
