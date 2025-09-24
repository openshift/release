#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"

echo "🚀 Creating Fusion Access pull secrets..."

# Check if namespace exists
if ! oc get namespace "${FUSION_ACCESS_NAMESPACE}" >/dev/null 2>&1; then
  echo "❌ ERROR: Namespace ${FUSION_ACCESS_NAMESPACE} does not exist"
  echo "Please ensure the namespace creation step runs before this step"
  exit 1
fi

echo "✅ Namespace ${FUSION_ACCESS_NAMESPACE} exists"

# Create fusion-pullsecret with IBM entitlement key
echo "Creating fusion-pullsecret..."
if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
  echo "✅ IBM entitlement key provided, creating fusion-pullsecret"
  oc create secret -n "${FUSION_ACCESS_NAMESPACE}" generic fusion-pullsecret \
    --from-literal=ibm-entitlement-key="${IBM_ENTITLEMENT_KEY}" \
    --dry-run=client -o yaml | oc apply -f -
  
  echo "Waiting for fusion-pullsecret to be ready..."
  oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret secret/fusion-pullsecret -n ${FUSION_ACCESS_NAMESPACE} --timeout=60s
  echo "✅ fusion-pullsecret created successfully"
else
  echo "⚠️  WARNING: IBM_ENTITLEMENT_KEY not provided, skipping fusion-pullsecret creation"
  echo "Some IBM images may not be accessible"
fi

# Create fusion-pullsecret-extra for additional registry access
echo "Creating fusion-pullsecret-extra..."
if [[ -n "${FUSION_PULL_SECRET_EXTRA:-}" ]]; then
  echo "✅ Additional pull secret provided, creating fusion-pullsecret-extra"
  oc apply -f=- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: fusion-pullsecret-extra
  namespace: ${FUSION_ACCESS_NAMESPACE}
stringData:
  .dockerconfigjson: |
    {
      "quay.io/openshift-storage-scale": {
        "auth": "${FUSION_PULL_SECRET_EXTRA}",
        "email": ""
      }
    }
type: kubernetes.io/dockerconfigjson
EOF
  
  echo "Waiting for fusion-pullsecret-extra to be ready..."
  oc wait --for=jsonpath='{.metadata.name}'=fusion-pullsecret-extra secret/fusion-pullsecret-extra -n ${FUSION_ACCESS_NAMESPACE} --timeout=60s
  echo "✅ fusion-pullsecret-extra created successfully"
else
  echo "⚠️  WARNING: FUSION_PULL_SECRET_EXTRA not provided, skipping fusion-pullsecret-extra creation"
  echo "Some registry images may not be accessible"
fi

echo "✅ All Fusion Access pull secrets created successfully!"
