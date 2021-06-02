#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

OO_BUNDLE="${OO_BUNDLE:-$BUNDLE_IMAGE}"
OO_INDEX="${OO_INDEX:-$INDEX_IMAGE}"
OO_PACKAGE="${OO_PACKAGE:-$PACKAGE}"
OO_CHANNEL="${OO_CHANNEL:-$CHANNEL}"
OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-$INSTALL_NAMESPACE}"
OO_TARGET_NAMESPACES="${OO_TARGET_NAMESPACES:-$TARGET_NAMESPACES}"

echo "Accessing the bundle image: $OO_BUNDLE"
oc image info --filter-by-os linux/amd64  -a /var/run/brew-pullsecret/.dockerconfigjson "$OO_BUNDLE"

echo "Accessing the index image: $OO_INDEX"
oc image info -a /var/run/brew-pullsecret/.dockerconfigjson "$OO_INDEX"

echo "Creating an artifact in $ARTIFACT_DIR"
cat > "$ARTIFACT_DIR/well-known-artifact" << EOF
OO_BUNDLE=$OO_BUNDLE
OO_INDEX=$OO_INDEX
OO_PACKAGE=$OO_PACKAGE
OO_CHANNEL=$OO_CHANNEL
OO_INSTALL_NAMESPACE=$OO_INSTALL_NAMESPACE
OO_TARGET_NAMESPACES=$OO_TARGET_NAMESPACES
EOF
