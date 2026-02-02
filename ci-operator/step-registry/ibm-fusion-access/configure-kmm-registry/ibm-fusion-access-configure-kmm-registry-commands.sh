#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__NAMESPACE="${FA__NAMESPACE:-ibm-fusion-access}"
FA__KMM__REGISTRY_URL="${FA__KMM__REGISTRY_URL:-}"
FA__KMM__REGISTRY_ORG="${FA__KMM__REGISTRY_ORG:-}"
FA__KMM__REGISTRY_REPO="${FA__KMM__REGISTRY_REPO:-gpfs-compat-kmod}"

echo "🔧 Configuring KMM Registry for Kernel Module Management..."

# Determine registry configuration
if [[ -n "$FA__KMM__REGISTRY_ORG" ]]; then
  # Use external registry (e.g., quay.io/org/repo)
  FINAL_REGISTRY_URL="${FA__KMM__REGISTRY_URL:-quay.io}"
  FULL_REPO="${FA__KMM__REGISTRY_ORG}/${FA__KMM__REGISTRY_REPO}"
  echo "Using external registry: ${FINAL_REGISTRY_URL}/${FULL_REPO}"
else
  # Use OpenShift internal registry
  FINAL_REGISTRY_URL="image-registry.openshift-image-registry.svc:5000"
  FULL_REPO="ibm-spectrum-scale/${FA__KMM__REGISTRY_REPO}"
  echo "Using internal OpenShift registry: ${FINAL_REGISTRY_URL}/${FULL_REPO}"
fi

# Create kmm-image-config ConfigMap in IBM Fusion Access namespace
echo ""
echo "Creating kmm-image-config in ${FA__NAMESPACE}..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kmm-image-config
  namespace: ${FA__NAMESPACE}
data:
  kmm_image_registry_url: "${FINAL_REGISTRY_URL}"
  kmm_image_repo: "${FULL_REPO}"
  kmm_tls_insecure: "false"
  kmm_tls_skip_verify: "false"
EOF

# Verify ConfigMap was created
if ! oc get configmap kmm-image-config -n "${FA__NAMESPACE}" >/dev/null; then
  echo "❌ Failed to create kmm-image-config in ${FA__NAMESPACE}"
  exit 1
fi

echo "✅ kmm-image-config created in ${FA__NAMESPACE}"

# Create kmm-image-config in ibm-spectrum-scale-operator namespace
# CRITICAL: IBM Storage Scale operator checks this namespace, not ibm-fusion-access
echo ""
echo "Creating kmm-image-config in ibm-spectrum-scale-operator namespace..."
echo "CRITICAL: IBM Storage Scale operator requires this ConfigMap in its own namespace"
echo "This prevents creation of broken buildgpl ConfigMap"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kmm-image-config
  namespace: ibm-spectrum-scale-operator
data:
  kmm_image_registry_url: "${FINAL_REGISTRY_URL}"
  kmm_image_repo: "${FULL_REPO}"
  kmm_tls_insecure: "false"
  kmm_tls_skip_verify: "false"
EOF

# Verify ConfigMap was created
if ! oc get configmap kmm-image-config -n ibm-spectrum-scale-operator >/dev/null; then
  echo "❌ Failed to create kmm-image-config in ibm-spectrum-scale-operator"
  exit 1
fi

echo "✅ kmm-image-config created in ibm-spectrum-scale-operator"

echo ""
echo "✅ KMM Registry configuration complete"
echo "Created in namespaces:"
echo "  - ${FA__NAMESPACE}"
echo "  - ibm-spectrum-scale-operator"
echo "Registry: ${FINAL_REGISTRY_URL}/${FULL_REPO}"
