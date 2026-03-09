#!/bin/bash

set -euxo pipefail

# Extract version from RELEASE_IMAGE_LATEST
# RELEASE_IMAGE_LATEST is provided by ci-operator when releases are defined
if [ -z "${RELEASE_IMAGE_LATEST:-}" ]; then
  echo "ERROR: RELEASE_IMAGE_LATEST is not set"
  exit 1
fi

# Verify ClusterImageSet CRD exists before proceeding
echo "Verifying ClusterImageSet CRD is available..."
if ! oc get crd clusterimagesets.hive.openshift.io &>/dev/null; then
  echo "ERROR: ClusterImageSet CRD not found"
  echo "This usually means the Hive operator hasn't finished initializing."
  echo "Available Hive CRDs:"
  oc get crds | grep hive || echo "No Hive CRDs found"
  exit 1
fi

echo "ClusterImageSet CRD is available"
echo "Creating ClusterImageSet for release: ${RELEASE_IMAGE_LATEST}"

# Extract version from release image (e.g., 4.21.0-nightly)
OCP_VERSION=$(oc adm release info "${RELEASE_IMAGE_LATEST}" -o jsonpath='{.metadata.version}' 2>/dev/null || echo "unknown")
echo "Detected OCP version: ${OCP_VERSION}"

# Create a unique ClusterImageSet name based on version and timestamp
# Format: img4.<version>-<timestamp>-ci
TIMESTAMP=$(date +%s)
CLUSTERIMAGESET_NAME="img4.${OCP_VERSION}-${TIMESTAMP}-ci"

# Create the ClusterImageSet
cat <<EOF | oc create -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: ${CLUSTERIMAGESET_NAME}
  labels:
    channel: ci
    visible: "true"
spec:
  releaseImage: ${RELEASE_IMAGE_LATEST}
EOF

echo "ClusterImageSet ${CLUSTERIMAGESET_NAME} created successfully"

# Save the name for potential use by subsequent steps
echo "${CLUSTERIMAGESET_NAME}" > "${SHARED_DIR}/clusterimageset-name"
