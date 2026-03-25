#!/bin/bash

set -o nounset
set -o pipefail

# Load credentials from the mounted secret as environment variables.
# Each file under the credentials directory becomes an env var whose
# name is the uppercased filename and whose value is the file content.
CREDS_DIR="/var/run/secrets/openshift-pipelines-e2e-credentials"
if [[ -d "${CREDS_DIR}" ]]; then
  for cred_file in "${CREDS_DIR}"/*; do
    [[ -f "${cred_file}" ]] || continue
    var_name="$(basename "${cred_file}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
    export "${var_name}"="$(cat "${cred_file}")"
  done
fi

CONSOLE_URL=$(cat "${SHARED_DIR}/console.url")
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export gauge_reports_dir="${ARTIFACT_DIR}"
export overwrite_reports=false
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export GOPROXY="https://proxy.golang.org/"

# Increase timeouts to avoid runner connection errors on larger clusters
gauge config runner_connection_timeout 600000
gauge config runner_request_timeout 300000

# Login - kubeadmin for IPI, api.login eval for ROSA/Hypershift
if [[ -f "${SHARED_DIR}/kubeadmin-password" ]]; then
  oc login -u kubeadmin -p "$(cat "${SHARED_DIR}/kubeadmin-password")" "${API_URL}" --insecure-skip-tls-verify=true
else
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

# Uninstall existing plugin (ignore failure if not present), then pin to known-good version
gauge uninstall xml-report 2>/dev/null || true
if ! gauge install xml-report --version 0.5.3; then
  echo "ERROR: Failed to install xml-report gauge plugin" >&2
  exit 1
fi

FAILED=0

echo "Running gauge e2e specs"
IFS=';' read -r -a specs <<< "${PIPELINES_TEST_SPECS}"
for spec in "${specs[@]}"; do
  # TLS tests are excluded because the cluster certificate chain is not provisioned
  # in the presubmit environment; they run in dedicated TLS periodic jobs instead.
  if ! gauge run --log-level=debug --verbose \
      --tags "${TEST_TAGS} & !tls" \
      --max-retries-count=3 --retry-only "${TEST_TAGS} & !tls" \
      ${spec}; then
    echo "ERROR: gauge spec failed: ${spec}" >&2
    FAILED=1
  fi
done

if ! gauge run --log-level=debug --verbose --tags "${TEST_TAGS}" specs/operator/rbac.spec; then
  echo "ERROR: gauge spec failed: specs/operator/rbac.spec" >&2
  FAILED=1
fi

echo "Renaming XML reports to junit_test_result<N>.xml"
counter=0
while IFS= read -r xml_file; do
  counter=$((counter + 1))
  mv "${xml_file}" "${ARTIFACT_DIR}/junit_test_result${counter}.xml"
done < <(find "${ARTIFACT_DIR}/xml-report/" -name '*.xml' 2>/dev/null)

if [[ ${FAILED} -eq 1 ]]; then
  echo "ERROR: One or more gauge test suites failed." >&2
  exit 1
fi
