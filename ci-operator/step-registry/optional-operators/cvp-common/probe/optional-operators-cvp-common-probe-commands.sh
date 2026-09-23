#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Accessing the bundle image: $BUNDLE_IMAGE"
oc image info --filter-by-os linux/amd64 -a /var/run/brew-pullsecret/.dockerconfigjson "$BUNDLE_IMAGE"

echo "Accessing the index image: $OO_INDEX"
oc image info --filter-by-os linux/amd64 -a /var/run/brew-pullsecret/.dockerconfigjson "$OO_INDEX"

echo "Creating an artifact in $ARTIFACT_DIR"
cat > "$ARTIFACT_DIR/well-known-artifact" << EOF
BUNDLE_IMAGE=$BUNDLE_IMAGE
OO_INDEX=$OO_INDEX
OO_PACKAGE=$OO_PACKAGE
OO_CHANNEL=$OO_CHANNEL
OO_INSTALL_NAMESPACE=$OO_INSTALL_NAMESPACE
OO_TARGET_NAMESPACES=$OO_TARGET_NAMESPACES
EOF
