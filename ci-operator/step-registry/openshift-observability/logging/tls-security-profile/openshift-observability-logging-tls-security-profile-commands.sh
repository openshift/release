#!/bin/bash

set -euo pipefail

if [[ -z "${LOGGING_TLS_SECURITY_PROFILE:-}" ]]; then
  echo "The TLS profile is missing!"
  exit 0
fi

function create_apiserver_manifests(){
    local MANIFESTS_DIR=$1
    local LOGGING_TLS_SECURITY_PROFILE=$2

    echo "Creating APIServer resource with the desired TLS configuration in the $MANIFESTS_DIR directory"

    cat > "${MANIFESTS_DIR}/logging-apiserver.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  tlsSecurityProfile:
$(echo "$LOGGING_TLS_SECURITY_PROFILE" | sed 's/^/    /')
  audit:
    profile: Default
EOF

    echo "Generated manifest:"
    cat "${MANIFESTS_DIR}/logging-apiserver.yaml"
    echo ''
}

create_apiserver_manifests "$SHARED_DIR" "$LOGGING_TLS_SECURITY_PROFILE"