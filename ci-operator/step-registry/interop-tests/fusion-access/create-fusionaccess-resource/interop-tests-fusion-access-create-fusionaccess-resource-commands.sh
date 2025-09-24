#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
FUSION_ACCESS_STORAGE_SCALE_VERSION="${FUSION_ACCESS_STORAGE_SCALE_VERSION:-5.2.3.1}"

echo "🚀 Creating FusionAccess resource..."

# Check if namespace exists
if ! oc get namespace "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "❌ ERROR: Namespace ${FUSION_ACCESS_NAMESPACE} does not exist"
  echo "Please ensure the namespace creation step runs before this step"
  exit 1
fi

echo "✅ Namespace ${FUSION_ACCESS_NAMESPACE} exists"

# Check if Fusion Access Operator is installed
echo "Checking if Fusion Access Operator is installed..."
if ! oc get csv -n "${FUSION_ACCESS_NAMESPACE}" | grep -q "fusion-access-operator"; then
  echo "❌ ERROR: Fusion Access Operator is not installed in namespace ${FUSION_ACCESS_NAMESPACE}"
  echo "Please ensure the operator installation step runs before this step"
  exit 1
fi

echo "✅ Fusion Access Operator is installed"

# Check if FusionAccess resource already exists
if oc get fusionaccess fusionaccess-object -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ FusionAccess resource already exists, skipping creation"
else
  echo "Creating FusionAccess resource..."
  oc apply -f=- <<EOF
apiVersion: fusion.storage.openshift.io/v1alpha1
kind: FusionAccess
metadata:
  name: fusionaccess-object
  namespace: ${FUSION_ACCESS_NAMESPACE}
spec:
  storageScaleVersion: ${FUSION_ACCESS_STORAGE_SCALE_VERSION}
  storageDeviceDiscovery:
    create: true
EOF
  
  echo "Waiting for FusionAccess to be ready..."
  oc wait --for=jsonpath='{.metadata.name}'=fusionaccess-object fusionaccess/fusionaccess-object -n ${FUSION_ACCESS_NAMESPACE} --timeout=600s
  
  echo "✅ FusionAccess resource created successfully"
fi

# Verify FusionAccess resource status
echo "Verifying FusionAccess resource status..."
oc get fusionaccess fusionaccess-object -n "${FUSION_ACCESS_NAMESPACE}" -o yaml

echo "✅ FusionAccess resource creation completed successfully!"
