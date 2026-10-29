#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "🚀 Creating namespaces for Fusion Access Operator and IBM Storage Scale..."

# Set default values from environment variables
FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"

echo "Fusion Access namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "Storage Scale namespace: ${STORAGE_SCALE_NAMESPACE}"

# Create Fusion Access namespace
echo "Creating Fusion Access namespace..."
if oc get namespace "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ Namespace ${FUSION_ACCESS_NAMESPACE} already exists"
else
  echo "Creating namespace ${FUSION_ACCESS_NAMESPACE}..."
  oc create namespace "${FUSION_ACCESS_NAMESPACE}"
fi

echo "Waiting for Fusion Access namespace to be ready..."
oc wait --for=jsonpath='{.status.phase}'=Active namespace/${FUSION_ACCESS_NAMESPACE} --timeout=60s

# Create IBM Storage Scale namespace
echo "Creating IBM Storage Scale namespace..."
if oc get namespace "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ Namespace ${STORAGE_SCALE_NAMESPACE} already exists"
else
  echo "Creating namespace ${STORAGE_SCALE_NAMESPACE}..."
  oc create namespace "${STORAGE_SCALE_NAMESPACE}"
fi

echo "Waiting for IBM Storage Scale namespace to be ready..."
oc wait --for=jsonpath='{.status.phase}'=Active namespace/${STORAGE_SCALE_NAMESPACE} --timeout=60s

echo "✅ Namespace creation completed successfully!"
echo "  - ${FUSION_ACCESS_NAMESPACE}: $(oc get namespace "${FUSION_ACCESS_NAMESPACE}" -o jsonpath='{.status.phase}')"
echo "  - ${STORAGE_SCALE_NAMESPACE}: $(oc get namespace "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.phase}')"
