#!/bin/bash

set -e
set -u
set -o pipefail

if  [ "$MCO_CONF_DAY1_TLS_PROFILE" == "" ]; then
  echo "The tls profile provided is empty"
  exit 0
fi

function create_apiserver_manifests(){
    local MANIFESTS_DIR=$1
    local MCO_CONF_DAY1_TLS_PROFILE=$2

    echo "Creating APIServer resource with the desired tls cofiguration in the $SHARED_DIR directory"

    cat > "${MANIFESTS_DIR}/99-apiserver.yaml" << EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  tlsSecurityProfile:
    $MCO_CONF_DAY1_TLS_PROFILE
  audit:
    profile: Default
EOF

cat "${MANIFESTS_DIR}/99-apiserver.yaml"
    echo ''
}

create_apiserver_manifests "$SHARED_DIR" "$MCO_CONF_DAY1_TLS_PROFILE"
