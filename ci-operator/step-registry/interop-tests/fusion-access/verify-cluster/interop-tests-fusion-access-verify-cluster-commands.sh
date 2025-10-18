#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

echo "🔍 Verifying IBM Storage Scale Cluster..."

# Verify cluster exists and is ready
oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}"

# Check cluster conditions
echo "Cluster conditions:"
oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" \
  -o jsonpath='{range .status.conditions[*]}  {.type}: {.status} - {.message}{"\n"}{end}'

# Check pods are running
echo ""
echo "IBM Storage Scale pods:"
oc get pods -n "${STORAGE_SCALE_NAMESPACE}"

echo ""
echo "✅ Cluster verification completed"
