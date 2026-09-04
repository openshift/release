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

# Verify required SHARED_DIR files exist
for f in api-endpoint oidc-endpoint customer-project-id; do
  if [[ ! -s "${SHARED_DIR}/${f}" ]]; then
    echo "ERROR: ${f} not found or empty in SHARED_DIR"
    echo "The gcp-hcp-tf-provision step must write this file"
    exit 1
  fi
done

# Authenticate with WIF credential
# - gcloud auth login: for gcloud CLI commands (access tokens)
# - GOOGLE_APPLICATION_CREDENTIALS: for GCP Go SDK clients used by
#   gcphcpctl --setup-infra (IAM, networking)
# - A temporary e2e-hc-submitter key: WIF credentials can't generate identity
#   tokens directly, so gcloud uses the submitter account for Platform API auth.
if [[ -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "Authenticating with WIF credential..."
  gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet
  export GOOGLE_APPLICATION_CREDENTIALS="${SHARED_DIR}/wif-cred.json"

  E2E_HC_SUBMITTER_SA="e2e-hc-submitter@gcp-hcp-platform-ci.iam.gserviceaccount.com"
  E2E_HC_SUBMITTER_KEY_DIR="$(mktemp -d)"
  E2E_HC_SUBMITTER_KEY_FILE="${E2E_HC_SUBMITTER_KEY_DIR}/key.json"
  E2E_HC_SUBMITTER_KEY_ID=""

  extract_e2e_hc_submitter_key_id() {
    sed -n 's/^[[:space:]]*"private_key_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p' "$1"
  }

  cleanup_e2e_hc_submitter_key() {
    local key_id="${E2E_HC_SUBMITTER_KEY_ID}"
    if [[ -z "${key_id}" && -s "${E2E_HC_SUBMITTER_KEY_FILE}" ]]; then
      key_id="$(extract_e2e_hc_submitter_key_id "${E2E_HC_SUBMITTER_KEY_FILE}")"
    fi

    if [[ -n "${key_id}" ]]; then
      echo "Deleting temporary e2e HC submitter key..."
      if gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet; then
        if ! gcloud iam service-accounts keys delete "${key_id}" \
          --iam-account="${E2E_HC_SUBMITTER_SA}" \
          --quiet; then
          echo "WARNING: Failed to delete temporary key ${key_id}"
        fi
      else
        echo "WARNING: Failed to restore WIF authentication; temporary key ${key_id} was not deleted"
      fi
    fi

    rm -f "${E2E_HC_SUBMITTER_KEY_FILE}"
    rmdir "${E2E_HC_SUBMITTER_KEY_DIR}" 2>/dev/null || true
  }
  trap cleanup_e2e_hc_submitter_key EXIT

  echo "Creating temporary key for ${E2E_HC_SUBMITTER_SA}..."
  gcloud iam service-accounts keys create "${E2E_HC_SUBMITTER_KEY_FILE}" \
    --iam-account="${E2E_HC_SUBMITTER_SA}" \
    --quiet
  E2E_HC_SUBMITTER_KEY_ID="$(extract_e2e_hc_submitter_key_id "${E2E_HC_SUBMITTER_KEY_FILE}")"
  if [[ -z "${E2E_HC_SUBMITTER_KEY_ID}" ]]; then
    echo "ERROR: Could not determine the temporary key ID"
    exit 1
  fi

  echo "Activating ${E2E_HC_SUBMITTER_SA} for identity token authentication..."
  MAX_KEY_ACTIVATION_ATTEMPTS=6
  key_activated=false
  for ((attempt = 1; attempt <= MAX_KEY_ACTIVATION_ATTEMPTS; attempt++)); do
    if gcloud auth activate-service-account "${E2E_HC_SUBMITTER_SA}" \
      --key-file="${E2E_HC_SUBMITTER_KEY_FILE}" \
      --quiet; then
      key_activated=true
      break
    fi

    if (( attempt < MAX_KEY_ACTIVATION_ATTEMPTS )); then
      wait_seconds=$((5 << (attempt - 1)))
      echo "Key activation failed; retrying in ${wait_seconds}s (attempt ${attempt}/${MAX_KEY_ACTIVATION_ATTEMPTS})..."
      sleep "${wait_seconds}"
    fi
  done

  if [[ "${key_activated}" != true ]]; then
    echo "ERROR: Failed to activate ${E2E_HC_SUBMITTER_SA} after ${MAX_KEY_ACTIVATION_ATTEMPTS} attempts"
    exit 1
  fi

  if ! gcloud auth print-identity-token >/dev/null; then
    echo "ERROR: Failed to generate an identity token for ${E2E_HC_SUBMITTER_SA}"
    exit 1
  fi
  echo "Identity token authentication verified successfully"
else
  echo "WARNING: WIF credential not found, relying on existing gcloud auth"
fi

# The Ginkgo binary reads these values from SHARED_DIR, but the standalone
# gcphcpctl readiness probe uses the CLI's environment-based configuration.
export GCPHCPCTL_API_ENDPOINT="$(cat "${SHARED_DIR}/api-endpoint")"
export GCPHCPCTL_PROJECT="$(cat "${SHARED_DIR}/customer-project-id")"

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
