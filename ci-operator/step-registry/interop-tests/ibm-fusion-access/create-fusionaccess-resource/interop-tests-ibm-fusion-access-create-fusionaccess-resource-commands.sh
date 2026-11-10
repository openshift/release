#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
FUSION_ACCESS_STORAGE_SCALE_VERSION="${FUSION_ACCESS_STORAGE_SCALE_VERSION:-5.2.3.1}"

echo "🚀 Creating FusionAccess resource..."

# Check if FusionAccess resource already exists (idempotent)
if oc get fusionaccess fusionaccess-object -n "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ FusionAccess resource already exists"
else
  # Create FusionAccess resource
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
  
  echo "Waiting for FusionAccess resource to be created..."
  oc wait --for=jsonpath='{.metadata.name}'=fusionaccess-object fusionaccess/fusionaccess-object -n ${FUSION_ACCESS_NAMESPACE} --timeout=600s
  
  echo "✅ FusionAccess resource created successfully"
fi

# Show resource status
echo "FusionAccess resource status:"
oc get fusionaccess fusionaccess-object -n "${FUSION_ACCESS_NAMESPACE}"
