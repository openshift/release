#!/bin/bash

set -euo pipefail

echo "[INFO] Creating ClusterImageSet for spoke cluster"

# Read spoke cluster name
SPOKE_CLUSTER_NAME="$(cat ${SHARED_DIR}/spoke-cluster-name)"

# Determine release image to use
if [[ -n "${SPOKE_RELEASE_IMAGE:-}" ]]; then
  RELEASE_IMAGE="${SPOKE_RELEASE_IMAGE}"
  echo "[INFO] Using specified SPOKE_RELEASE_IMAGE: ${RELEASE_IMAGE}"
else
  # Use the RELEASE_IMAGE from dependencies (injected by CI Operator)
  # This will be the release defined in the CI config
  RELEASE_IMAGE="${RELEASE_IMAGE:-registry.ci.openshift.org/ocp/release:4.22.0-0.nightly}"
  echo "[INFO] Using RELEASE_IMAGE dependency: ${RELEASE_IMAGE}"
fi

# Create unique ClusterImageSet name
IMAGESET_NAME="img-${SPOKE_CLUSTER_NAME}"
echo "[INFO] ClusterImageSet name: ${IMAGESET_NAME}"

# Create ClusterImageSet
cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: ${IMAGESET_NAME}
spec:
  releaseImage: ${RELEASE_IMAGE}
EOF

echo "[SUCCESS] ClusterImageSet created: ${IMAGESET_NAME}"

# Save imageset name for next step
echo "${IMAGESET_NAME}" > "${SHARED_DIR}/spoke-clusterimageset-name"

# Verify ClusterImageSet was created
oc get clusterimageset "${IMAGESET_NAME}" -o yaml

echo "[INFO] Release image: ${RELEASE_IMAGE}"
