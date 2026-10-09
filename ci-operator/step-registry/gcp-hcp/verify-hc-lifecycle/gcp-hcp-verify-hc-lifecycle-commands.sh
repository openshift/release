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
for f in api-endpoint oidc-endpoint customer-project-id region region-project-id; do
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

# Reuse the service account configured for WIF for the activation workflow,
# public API bootstrap, and gcphcpctl lifecycle requests. The WIF auth step
# uses this same value to construct wif-cred.json.
WIF_CONFIG="${CLUSTER_PROFILE_DIR}/wif-config.json"
if [[ ! -r "${WIF_CONFIG}" ]]; then
  echo "ERROR: WIF configuration not found or unreadable: ${WIF_CONFIG}"
  exit 1
fi
WIF_SERVICE_ACCOUNT_EMAIL=$(jq -r '.service_account // empty' "${WIF_CONFIG}")
if [[ ! "${WIF_SERVICE_ACCOUNT_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; then
  echo "ERROR: .service_account is missing or invalid in ${WIF_CONFIG}"
  exit 1
fi
printf '%s\n' "${WIF_SERVICE_ACCOUNT_EMAIL}" > "${SHARED_DIR}/platform-api-subject-email"
if [[ ! -s "${SHARED_DIR}/platform-api-subject-email" ]]; then
  echo "ERROR: Failed to write the Platform API subject identity"
  exit 1
fi

# The Ginkgo binary reads its configuration from SHARED_DIR. Keep these values
# available as environment configuration for gcphcpctl calls made by the test.
GCPHCPCTL_API_ENDPOINT="$(cat "${SHARED_DIR}/api-endpoint")"
GCPHCPCTL_PROJECT="$(cat "${SHARED_DIR}/customer-project-id")"
GCPHCPCTL_REGION="$(cat "${SHARED_DIR}/region")"
export GCPHCPCTL_API_ENDPOINT GCPHCPCTL_PROJECT GCPHCPCTL_REGION

# Wait for the unauthenticated platform API readiness endpoint before starting
# the lifecycle test. Authentication is bootstrapped by the Ginkgo test before
# any authenticated lifecycle request is made.
wait_for_platform_api() {
  local max_attempts="${GCPHCPCTL_API_MAX_ATTEMPTS:-40}"
  local wait_seconds="${GCPHCPCTL_API_WAIT_SECONDS:-30}"
  local attempt=1
  local http_code

  if [[ ! "${max_attempts}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: GCPHCPCTL_API_MAX_ATTEMPTS must be a positive integer"
    return 1
  fi

  echo ""
  echo "=== Waiting for platform API readiness ==="
  echo "Polling /readyz (up to ${max_attempts} attempts, ${wait_seconds}s apart)..."

  while (( attempt <= max_attempts )); do
    if http_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --max-time 15 "${GCPHCPCTL_API_ENDPOINT}/readyz")" \
      && [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
      echo "✓ Platform API is ready (attempt ${attempt})"
      return 0
    fi

    echo "⚠ Platform API is not ready yet (attempt ${attempt}/${max_attempts})"

    if (( attempt == max_attempts )); then
      echo "ERROR: Platform API did not become ready after ${max_attempts} attempts"
      return 1
    fi

    sleep "${wait_seconds}"
    ((attempt++))
  done
}

if ! wait_for_platform_api; then
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
