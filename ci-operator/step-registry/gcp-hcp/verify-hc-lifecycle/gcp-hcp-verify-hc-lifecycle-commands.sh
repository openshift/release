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
# - gcloud auth login: for gcloud CLI commands and identity tokens
# - GOOGLE_APPLICATION_CREDENTIALS: for GCP Go SDK clients used by
#   gcphcpctl --setup-infra (IAM, networking)
if [[ -f "${SHARED_DIR}/wif-cred.json" ]]; then
  echo "Authenticating with WIF credential..."
  gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet
  export GOOGLE_APPLICATION_CREDENTIALS="${SHARED_DIR}/wif-cred.json"
else
  echo "WARNING: WIF credential not found, relying on existing gcloud auth"
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
