#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Accessing the bundle image: $BUNDLE_IMAGE"
oc image info --filter-by-os linux/amd64 -a /var/run/brew-pullsecret/.dockerconfigjson "$BUNDLE_IMAGE"

echo "Accessing the index image: $INDEX_IMAGE"
oc image info --filter-by-os linux/amd64 -a /var/run/brew-pullsecret/.dockerconfigjson "$INDEX_IMAGE"

echo "Creating an artifact in $ARTIFACT_DIR"
cat > "$ARTIFACT_DIR/well-known-artifact" << EOF
BUNDLE_IMAGE=$BUNDLE_IMAGE
INDEX_IMAGE=$INDEX_IMAGE
PACKAGE=$PACKAGE
CHANNEL=$CHANNEL
INSTALL_NAMESPACE=$INSTALL_NAMESPACE
TARGET_NAMESPACES=$TARGET_NAMESPACES
EOF
