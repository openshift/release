#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "🔧 Creating catalog source for Fusion Access Operator..."

# Create catalog source
echo "Creating catalog source: ${CATALOG_SOURCE_NAME}"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: ${CATALOG_SOURCE_NAMESPACE}
spec:
  displayName: Test Storage Scale Operator
  image: ${CATALOG_SOURCE_IMAGE}
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF

# Wait for catalog source to be ready
echo "Waiting for catalog source to be ready..."
COUNTER=0
while [ $COUNTER -lt 600 ]; do
  COUNTER=$((COUNTER + 20))
  echo "Waiting ${COUNTER}s for catalog source to be ready..."
  sleep 20
  
  STATUS=$(oc get catalogsource "${CATALOG_SOURCE_NAME}" -n "${CATALOG_SOURCE_NAMESPACE}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "Unknown")
  echo "Catalog source status: ${STATUS}"
  
  if [ "$STATUS" = "READY" ]; then
    echo "✅ Catalog source ${CATALOG_SOURCE_NAME} is ready"
    break
  fi
  
  if [ $COUNTER -ge 600 ]; then
    echo "❌ Timeout waiting for catalog source to be ready"
    echo "Catalog source details:"
    oc get catalogsource "${CATALOG_SOURCE_NAME}" -n "${CATALOG_SOURCE_NAMESPACE}" -o yaml || true
    echo "Catalog source pods:"
    oc get pods -n "${CATALOG_SOURCE_NAMESPACE}" -l olm.catalogSource="${CATALOG_SOURCE_NAME}" || true
    exit 1
  fi
done

# Verify catalog source is working
echo "Verifying catalog source..."
oc get catalogsource "${CATALOG_SOURCE_NAME}" -n "${CATALOG_SOURCE_NAMESPACE}" -o yaml

echo "✅ Catalog source creation completed successfully"
