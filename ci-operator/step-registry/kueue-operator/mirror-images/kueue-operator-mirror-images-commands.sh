#!/bin/bash
set -euxo pipefail

echo "===== Kueue Image Mirror for Disconnected Testing ====="
echo "Date: $(date)"

# Get cluster info
echo "Cluster: $(oc whoami --show-server)"
oc get clusterversion -o yaml

# Determine internal registry
INTERNAL_REGISTRY=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
echo "Internal registry: ${INTERNAL_REGISTRY}"

# Get Kueue version from operator source
# This assumes the kueue-operator source is available
KUEUE_VERSION="${KUEUE_VERSION:-v0.10.0}"
if [ -f "${SHARED_DIR}/KUEUE_VERSION" ]; then
  KUEUE_VERSION=$(cat "${SHARED_DIR}/KUEUE_VERSION")
fi
echo "Kueue version: ${KUEUE_VERSION}"

# Source images (adjust these based on actual Kueue images)
BUNDLE_SOURCE="quay.io/openshift-kueue/kueue-operator-bundle:${KUEUE_VERSION}"
OPERATOR_SOURCE="quay.io/openshift-kueue/kueue-operator:${KUEUE_VERSION}"
OPERAND_SOURCE="quay.io/openshift-kueue/kueue:${KUEUE_VERSION}"

# Target paths in internal registry
BUNDLE_TARGET="${INTERNAL_REGISTRY}/openshift-kueue-operator/kueue-operator-bundle:${KUEUE_VERSION}"
OPERATOR_TARGET="${INTERNAL_REGISTRY}/openshift-kueue-operator/kueue-operator:${KUEUE_VERSION}"
OPERAND_TARGET="${INTERNAL_REGISTRY}/openshift-kueue-operator/kueue:${KUEUE_VERSION}"

# Create namespace for mirrored images
oc create namespace openshift-kueue-operator || true

# Login to internal registry
echo "Logging into internal registry..."
oc registry login

# Mirror images
echo "Mirroring bundle image..."
oc image mirror \
  "${BUNDLE_SOURCE}" \
  "${BUNDLE_TARGET}" \
  --keep-manifest-list=true \
  --filter-by-os='.*' \
  --insecure=true \
  --skip-multiple-scopes \
  --continue-on-error=true

echo "Mirroring operator image..."
oc image mirror \
  "${OPERATOR_SOURCE}" \
  "${OPERATOR_TARGET}" \
  --keep-manifest-list=true \
  --filter-by-os='.*' \
  --insecure=true \
  --skip-multiple-scopes \
  --continue-on-error=true

echo "Mirroring operand image..."
oc image mirror \
  "${OPERAND_SOURCE}" \
  "${OPERAND_TARGET}" \
  --keep-manifest-list=true \
  --filter-by-os='.*' \
  --insecure=true \
  --skip-multiple-scopes \
  --continue-on-error=true

# Create ImageContentSourcePolicy
echo "Creating ImageContentSourcePolicy..."
cat <<YAML | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: kueue-mirror
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${INTERNAL_REGISTRY}/openshift-kueue-operator
    source: quay.io/openshift-kueue
YAML

# Wait for MachineConfigPool to apply changes
echo "Waiting for MachineConfigPool updates..."
sleep 10  # Give it a moment to start updating

# Check if MCPs exist and wait for them
if oc get mcp master >/dev/null 2>&1; then
  oc wait mcp/master --for=condition=Updated --timeout=15m || true
fi

if oc get mcp worker >/dev/null 2>&1; then
  oc wait mcp/worker --for=condition=Updated --timeout=15m || true
fi

echo "===== Image Mirror Complete ====="
echo "Mirrored images:"
echo "  Bundle: ${BUNDLE_TARGET}"
echo "  Operator: ${OPERATOR_TARGET}"
echo "  Operand: ${OPERAND_TARGET}"

# Save mirror info for test step
echo "${INTERNAL_REGISTRY}" > "${SHARED_DIR}/INTERNAL_REGISTRY"
echo "${KUEUE_VERSION}" > "${SHARED_DIR}/KUEUE_VERSION"
