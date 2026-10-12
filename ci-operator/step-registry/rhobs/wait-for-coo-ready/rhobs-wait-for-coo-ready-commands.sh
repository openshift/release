#!/bin/bash
set -euo pipefail

echo "Waiting for COO deployments in namespace ${COO_NAMESPACE}..."
oc wait -n "${COO_NAMESPACE}" --for=condition=Available deploy/observability-operator --timeout=300s
oc wait -n "${COO_NAMESPACE}" --for=condition=Available deploy/obo-prometheus-operator --timeout=300s
oc wait -n "${COO_NAMESPACE}" --for=condition=Available deploy/obo-prometheus-operator-admission-webhook --timeout=300s
echo "All COO deployments are available."
