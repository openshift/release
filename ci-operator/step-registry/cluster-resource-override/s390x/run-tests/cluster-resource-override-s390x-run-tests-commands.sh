#!/bin/bash

set -euo pipefail

echo "=== ClusterResourceOverride s390x e2e ==="
echo "Namespace: ${CRO_NAMESPACE}"
echo "E2E_SKIP: ${E2E_SKIP:-<none>}"

echo "=== Operator status before tests ==="
oc get deployment,pods,csv,subscription -n "${CRO_NAMESPACE}" -o wide || true
oc get clusterresourceoverride -A -o wide || true

oc wait --for=condition=Available deployment/clusterresourceoverride-operator \
  -n "${CRO_NAMESPACE}" --timeout=600s

# make e2e expects OPERATOR_NAMESPACE and KUBECONFIG; KUBECONFIG is injected by ci-operator.
export OPERATOR_NAMESPACE="${CRO_NAMESPACE}"
KUBECTL="$(which oc)"
export KUBECTL

echo "=== Running make e2e ==="
make e2e E2E_SKIP="${E2E_SKIP}" OPERATOR_NAMESPACE="${CRO_NAMESPACE}" KUBECTL="${KUBECTL}"

echo "=== e2e complete ==="
