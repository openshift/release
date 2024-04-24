#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
QUAY_INDEX_IMAGE_BUILD="$QUAY_INDEX_IMAGE_BUILD"

#"redhat-operators" is official catalog source for released build
if [ $QUAY_OPERATOR_SOURCE == "redhat-operators" ]; then #Install Quay Operator with released build
  echo "Installing Quay from released build"
elif [ -z "$QUAY_INDEX_IMAGE_BUILD" ]; then  
  echo "Installing from custom catalog source $QUAY_OPERATOR_SOURCE, but not provoide index image: $QUAY_INDEX_IMAGE_BUILD"
  exit 1
else #Install Quay operator with iib
  echo "Installing Quay from unreleased iib: $QUAY_INDEX_IMAGE_BUILD" 
  
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
