#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
FUSION_ACCESS_STORAGE_SCALE_VERSION="${FUSION_ACCESS_STORAGE_SCALE_VERSION:-5.2.3.1}"

echo "🚀 Creating FusionAccess resource..."

# Debug: List all namespaces to see what's available
echo "🔍 Debug: Listing all namespaces in the cluster..."
oc get namespaces --no-headers | awk '{print $1}' | sort

# Debug: Check current context
echo "🔍 Debug: Current cluster context..."
oc config current-context

# Debug: Check if we can access the cluster
echo "🔍 Debug: Cluster access test..."
oc get nodes --no-headers | wc -l
echo " nodes found in cluster"

# Check if namespace exists with retry mechanism
echo "🔍 Debug: Checking for namespace ${FUSION_ACCESS_NAMESPACE}..."
MAX_RETRIES=10
RETRY_COUNT=0

while ! oc get namespace "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -gt $MAX_RETRIES ]; then
    echo "❌ ERROR: Namespace ${FUSION_ACCESS_NAMESPACE} does not exist after ${MAX_RETRIES} retries"
    echo "Available namespaces:"
    oc get namespaces --no-headers | awk '{print "  - " $1}'
    echo "Please ensure the namespace creation step runs before this step"
    exit 1
  fi
  echo "⏳ Namespace ${FUSION_ACCESS_NAMESPACE} not found, retrying... (${RETRY_COUNT}/${MAX_RETRIES})"
  sleep 10
done

echo "✅ Namespace ${FUSION_ACCESS_NAMESPACE} exists"

# Check if Fusion Access Operator is installed with retry mechanism
echo "Checking if Fusion Access Operator is installed..."
MAX_OPERATOR_RETRIES=20
OPERATOR_RETRY_COUNT=0

while ! oc get csv -n "${FUSION_ACCESS_NAMESPACE}" | grep -q "fusion-access-operator"; do
  OPERATOR_RETRY_COUNT=$((OPERATOR_RETRY_COUNT + 1))
  if [ $OPERATOR_RETRY_COUNT -gt $MAX_OPERATOR_RETRIES ]; then
    echo "❌ ERROR: Fusion Access Operator is not installed in namespace ${FUSION_ACCESS_NAMESPACE} after ${MAX_OPERATOR_RETRIES} retries"
    echo "Available CSVs in namespace:"
    oc get csv -n "${FUSION_ACCESS_NAMESPACE}" --no-headers | awk '{print "  - " $1}' || echo "  No CSVs found"
    echo "Please ensure the operator installation step runs before this step"
    exit 1
  fi
  echo "⏳ Fusion Access Operator not found, retrying... (${OPERATOR_RETRY_COUNT}/${MAX_OPERATOR_RETRIES})"
  sleep 15
done

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
