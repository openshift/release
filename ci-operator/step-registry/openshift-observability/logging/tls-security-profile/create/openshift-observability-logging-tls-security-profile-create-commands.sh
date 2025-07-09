#!/bin/bash

set -euo pipefail

# Validate input
if [[ -z "${LOGGING_TLS_SECURITY_PROFILE:-}" ]]; then
  echo "Error: LOGGING_TLS_SECURITY_PROFILE is not set."
  exit 1
fi

# Create the APIServer manifest YAML
create_apiserver_manifest() {
  local manifests_dir=$1
  local tls_profile=$2
  local manifest_path="${manifests_dir}/logging-apiserver.yaml"

  echo "Creating APIServer manifest at: ${manifest_path}"

cat > "${manifest_path}" <<EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  tlsSecurityProfile:
$(echo "${tls_profile}" | sed 's/^/    /')
  audit:
    profile: Default
EOF

  echo "Generated manifest:"
  cat "${manifest_path}"
  echo ""
}

create_apiserver_manifest "$SHARED_DIR" "$LOGGING_TLS_SECURITY_PROFILE"
