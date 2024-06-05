#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
QUAY_INDEX_IMAGE_BUILD="$QUAY_INDEX_IMAGE_BUILD"

#create image content source policy
function create_icsp () {
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
  if [ $? == 0 ]; then
    echo "Create the ICSP successfully" 
  else
    echo "!!! Fail to create the ICSP"
    return 1
  fi

}

#Create custom catalog source
function create_catalog_source(){
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

}

#Check catalog source status to Ready
function check_catalog_source_status(){
    set +e 
    COUNTER=0
    while [ $COUNTER -lt 600 ] #10 min at most
    do
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        sleep 20
        STATUS=`oc get catalogsources -n openshift-marketplace $QUAY_OPERATOR_SOURCE -o=jsonpath="{.status.connectionState.lastObservedState}"`
        if [[ $STATUS = "READY" ]]; then
            echo "Create Quay CatalogSource successfully"
            break
        fi
    done
    if [[ $STATUS != "READY" ]]; then
        echo "!!! Fail to create Quay CatalogSource"
         return 1
    fi
    set -e 
}


#"redhat-operators" is official catalog source for released build
if [ $QUAY_OPERATOR_SOURCE == "redhat-operators" ]; then 
  echo "Installing Quay from released build"
elif [ -z "$QUAY_INDEX_IMAGE_BUILD" ]; then 
  echo "Installing from custom catalog source $QUAY_OPERATOR_SOURCE, but not provoide index image: $QUAY_INDEX_IMAGE_BUILD"
  exit 1
else #Install Quay operator with iib
  echo "Installing Quay from unreleased iib: $QUAY_INDEX_IMAGE_BUILD" 
  create_icsp
  create_catalog_source
  check_catalog_source_status
  
fi
