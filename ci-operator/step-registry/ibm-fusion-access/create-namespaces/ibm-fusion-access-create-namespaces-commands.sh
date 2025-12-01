#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🚀 Creating namespaces for IBM Fusion Access Operator and IBM Storage Scale..."

# Set default values from environment variables
FUSION_ACCESS_NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"

echo "IBM Fusion Access namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "Storage Scale namespace: ${FA__SCALE__NAMESPACE}"

# Create IBM Fusion Access namespace
echo "Creating IBM Fusion Access namespace..."
if oc get namespace "${FUSION_ACCESS_NAMESPACE}" >/dev/null; then
  echo "✅ Namespace ${FUSION_ACCESS_NAMESPACE} already exists"
else
  echo "Creating namespace ${FUSION_ACCESS_NAMESPACE}..."
  oc create namespace "${FUSION_ACCESS_NAMESPACE}"
fi

echo "Waiting for IBM Fusion Access namespace to be ready..."
oc wait --for=jsonpath='{.status.phase}'=Active namespace/${FUSION_ACCESS_NAMESPACE} --timeout=60s

# Create IBM Storage Scale namespace
echo "Creating IBM Storage Scale namespace..."
if oc get namespace "${FA__SCALE__NAMESPACE}" >/dev/null; then
  echo "✅ Namespace ${FA__SCALE__NAMESPACE} already exists"
else
  echo "Creating namespace ${FA__SCALE__NAMESPACE}..."
  oc create namespace "${FA__SCALE__NAMESPACE}"
fi

echo "Waiting for IBM Storage Scale namespace to be ready..."
oc wait --for=jsonpath='{.status.phase}'=Active namespace/${FA__SCALE__NAMESPACE} --timeout=60s

echo "✅ Namespace creation completed successfully!"
echo "  - ${FUSION_ACCESS_NAMESPACE}: $(oc get namespace "${FUSION_ACCESS_NAMESPACE}" -o jsonpath='{.status.phase}')"
echo "  - ${FA__SCALE__NAMESPACE}: $(oc get namespace "${FA__SCALE__NAMESPACE}" -o jsonpath='{.status.phase}')"
