#!/bin/bash

set -euxo pipefail

# Extract version from RELEASE_IMAGE_LATEST
# RELEASE_IMAGE_LATEST is provided by ci-operator when releases are defined
if [ -z "${RELEASE_IMAGE_LATEST:-}" ]; then
  echo "ERROR: RELEASE_IMAGE_LATEST is not set"
  exit 1
fi

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
