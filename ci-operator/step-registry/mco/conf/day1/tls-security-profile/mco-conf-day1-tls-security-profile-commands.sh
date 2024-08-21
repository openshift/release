#!/bin/bash

set -e
set -u
set -o pipefail

function create_apiserver_manifests(){
    local MANIFESTS_DIR=$1
    local MCO_CONF_DAY1_TLS_PROFILE_TYPE=$2

    echo "Creating APIServer resource with the desired tls cofiguration in the $SHARED_DIR directory"

    cat > "${MANIFESTS_DIR}/99-apiserver.yaml" << EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  tlsSecurityProfile:
    type: $MCO_CONF_DAY1_TLS_PROFILE_TYPE 
    custom: 
      ciphers: 
      - ECDHE-ECDSA-CHACHA20-POLY1305
      - ECDHE-RSA-CHACHA20-POLY1305
      - ECDHE-RSA-AES128-GCM-SHA256
      - ECDHE-ECDSA-AES128-GCM-SHA256
      minTLSVersion: VersionTLS11
  audit:
    profile: Default
EOF

cat "${MANIFESTS_DIR}/99-apiserver.yaml"
    echo ''
}

create_apiserver_manifests "$SHARED_DIR" "$MCO_CONF_DAY1_TLS_PROFILE_TYPE"