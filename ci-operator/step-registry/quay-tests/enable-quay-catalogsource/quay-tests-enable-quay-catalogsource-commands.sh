#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
QUAY_INDEX_IMAGE_BUILD="$QUAY_INDEX_IMAGE_BUILD"

#By default, install Quay Operator with released build
if [ -z "$QUAY_INDEX_IMAGE_BUILD" ] && [ QUAY_OPERATOR_SOURCE == "redhat-operators"]; then
  echo "Installing Quay from released build"
else  #Install Quay operator with iib
  echo "Installing Quay from unreleased iib: $QUAY_INDEX_IMAGE_BUILD" 
  # QUAY_OPERATOR_SOURCE="brew-operator-catalog"
  
  #create image content source policy
  cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: brew-registry
spec:
  repositoryDigestMirrors:
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/quay-quay-operator-rhel8
    source: registry.redhat.io/quay/quay-operator-rhel8
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/quay-quay-rhel8
    source: registry.redhat.io/quay/quay-rhel8
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/quay-quay-bridge-operator-rhel8
    source: registry.redhat.io/quay/quay-bridge-operator-rhel8
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/quay-quay-bridge-operator-rhel8
    source: registry.redhat.io/quay/quay-bridge-rhel9-operator
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/quay-quay-container-security-operator-rhel8
    source: registry.redhat.io/quay/quay-container-security-operator-rhel8
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/quay-clair-rhel8
    source: registry.redhat.io/quay/clair-rhel8
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
EOF
  
  #Create custom catalog source
  cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $QUAY_OPERATOR_SOURCE
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $QUAY_INDEX_IMAGE_BUILD
  displayName: Brew Testing Operator Catalog
  publisher: grpc
EOF

fi
