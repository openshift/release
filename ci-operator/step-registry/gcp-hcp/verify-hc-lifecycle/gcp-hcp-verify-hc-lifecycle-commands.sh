#!/usr/bin/env bash
set -euo pipefail

echo "=== GCP HCP HC Lifecycle Validation ==="
echo ""

# Verify gcphcpctl binary exists (built into the gcp-hcp-e2e-tests image)
if [[ ! -f "/usr/bin/gcphcpctl" ]]; then
  echo "ERROR: gcphcpctl binary not found at /usr/bin/gcphcpctl"
  echo "The gcp-hcp-e2e-tests image must include gcphcpctl"
  exit 1
fi
if [[ ! -x "/usr/bin/test-e2e" ]]; then
  echo "ERROR: test-e2e binary not found or not executable at /usr/bin/test-e2e"
  echo "The gcp-hcp-e2e-tests image must include test-e2e"
  exit 1
fi

# Verify required SHARED_DIR files exist
for f in api-endpoint oidc-endpoint customer-project-id; do
  if [[ ! -s "${SHARED_DIR}/${f}" ]]; then
    echo "ERROR: ${f} not found or empty in SHARED_DIR"
    echo "The gcp-hcp-tf-provision step must write this file"
    exit 1
  fi
done

# Configure Application Default Credentials for gcphcpctl. The CLI uses the
# WIF credential for both Platform API identity tokens and GCP SDK operations.
if [[ ! -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "ERROR: WIF credential not found"
  exit 1
fi
echo "Configuring gcphcpctl with the WIF credential..."
export GOOGLE_APPLICATION_CREDENTIALS="${SHARED_DIR}/wif-cred.json"

# The Ginkgo binary reads these values from SHARED_DIR, but the standalone
# gcphcpctl readiness probe uses the CLI's environment-based configuration.
GCPHCPCTL_API_ENDPOINT="$(cat "${SHARED_DIR}/api-endpoint")"
GCPHCPCTL_PROJECT="$(cat "${SHARED_DIR}/customer-project-id")"
export GCPHCPCTL_API_ENDPOINT GCPHCPCTL_PROJECT

# Wait for the authenticated Gecko API path to be ready before starting the
# lifecycle test. ArgoCD sync only confirms that manifests were applied; it
# does not guarantee that the API gateway/backend can serve requests yet.
wait_for_gcphcp_api() {
  local max_attempts="${GCPHCPCTL_API_MAX_ATTEMPTS:-40}"
  local wait_seconds="${GCPHCPCTL_API_WAIT_SECONDS:-30}"
  local attempt=1
  local output=""

  echo ""
  echo "=== Waiting for authenticated gcphcpctl API readiness ==="
  echo "Polling cluster list (up to ${max_attempts} attempts, ${wait_seconds}s apart)..."

  while (( attempt <= max_attempts )); do
    if output="$(gcphcpctl cluster list 2>&1)"; then
      echo "✓ gcphcpctl API is ready (attempt ${attempt})"
      if [[ -n "${output}" ]]; then
        echo "${output}"
      fi
      return 0
    fi

    echo "⚠ gcphcpctl API is not ready yet (attempt ${attempt}/${max_attempts})"
    if [[ -n "${output}" ]]; then
      echo "${output}"
    fi

    if (( attempt == max_attempts )); then
      echo "ERROR: gcphcpctl API did not become ready after ${max_attempts} attempts"
      return 1
    fi

    sleep "${wait_seconds}"
    ((attempt++))
  done
}

if ! wait_for_gcphcp_api; then
  echo ""
  echo "=== gcphcpctl API readiness diagnostics ==="
  echo "API endpoint: $(cat "${SHARED_DIR}/api-endpoint")"
  echo "Customer project: $(cat "${SHARED_DIR}/customer-project-id")"
  echo "DNS lookup:"
  getent hosts "$(sed -E 's#https?://([^/]+)/?.*#\1#' "${SHARED_DIR}/api-endpoint")" || true
  exit 1
fi

echo "Configuration:"
echo "  API endpoint:       $(cat "${SHARED_DIR}/api-endpoint")"
echo "  OIDC endpoint:      $(cat "${SHARED_DIR}/oidc-endpoint")"
echo "  Customer project:   $(cat "${SHARED_DIR}/customer-project-id")"
echo "  HC version:         ${HC_VERSION:-5.0.0-ec.6}"
echo "  Channel group:      ${HC_CHANNEL_GROUP:-candidate}"
echo ""

# The Ginkgo test reads SHARED_DIR files directly via resolveConfig().
# GCPHCPCTL_PATH points to the binary baked into the test image.
export GCPHCPCTL_PATH="/usr/bin/gcphcpctl"

# Run Ginkgo v2 test binary
echo "Running HC lifecycle validation tests..."
/usr/bin/test-e2e \
  --ginkgo.v \
  --ginkgo.no-color \
  --ginkgo.timeout=140m \
  --ginkgo.junit-report="${ARTIFACT_DIR}/junit_hc_lifecycle.xml" \
  --ginkgo.label-filter="hc-lifecycle"

echo ""
echo "HC lifecycle validation completed successfully"
touch "${SHARED_DIR}/gcp-hcp-e2e-tests-passed"
