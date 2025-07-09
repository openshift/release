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

# Wait for the APIServer cluster object to exist
wait_for_apiserver() {
  echo "Waiting for APIServer 'cluster' resource..."
  local retries=30
  local interval=5

  for ((i=1; i<=retries; i++)); do
    if oc get apiserver cluster &>/dev/null; then
      echo "APIServer 'cluster' is available."
      return 0
    fi
    sleep "${interval}"
  done

  echo "Timed out waiting for APIServer 'cluster'."
  return 1
}

# Compare current TLS profile against the expected one
verify_apiserver_tls_profile() {
  echo "Verifying APIServer TLS Security Profile..."

  local current expected
  if ! current=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile}' 2>/dev/null | jq -c .); then
    echo "Error: Failed to retrieve TLS profile from APIServer."
    return 1
  fi

  if ! expected=$(echo "${LOGGING_TLS_SECURITY_PROFILE}" | jq -c .); then
    echo "Error: Failed to parse expected TLS profile."
    return 1
  fi

  echo "Expected TLS profile: ${expected}"
  echo "Current TLS profile:  ${current}"

  if [[ "${current}" != "${expected}" ]]; then
    echo "Error: TLS profile does not match the expected configuration."
    return 1
  fi

  echo "TLS profile matches expected configuration."
}

create_apiserver_manifest "$SHARED_DIR" "$LOGGING_TLS_SECURITY_PROFILE"
wait_for_apiserver
verify_apiserver_tls_profile
