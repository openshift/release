#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This value serves as a default when the parameters are not set, which should
# only happen in rehearsals. Production jobs should always set the OO_* variable.
REHEARSAL_BUNDLE="brew.registry.redhat.io/rh-osbs-stage/e2e-e2e-test-operator-bundle-container:8.0-3"
REHEARSAL_INDEX="brew.registry.redhat.io/rh-osbs-stage/iib:23576"
REHEARSAL_PACKAGE="e2e-test-operator"
REHEARSAL_CHANNEL="4.3"
REHEARSAL_INSTALL_NAMESPACE="!create"
REHEARSAL_TARGET_NAMESPACES="!install"

OO_BUNDLE="${OO_BUNDLE:-$REHEARSAL_BUNDLE}"
OO_INDEX="${OO_INDEX:-$REHEARSAL_INDEX}"
OO_PACKAGE="${OO_PACKAGE:-$REHEARSAL_PACKAGE}"
OO_CHANNEL="${OO_CHANNEL:-$REHEARSAL_CHANNEL}"
OO_INSTALL_NAMESPACE="${OO_INSTALL_NAMESPACE:-$REHEARSAL_INSTALL_NAMESPACE}"
OO_TARGET_NAMESPACES="${OO_TARGET_NAMESPACES:-$REHEARSAL_TARGET_NAMESPACES}"

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
