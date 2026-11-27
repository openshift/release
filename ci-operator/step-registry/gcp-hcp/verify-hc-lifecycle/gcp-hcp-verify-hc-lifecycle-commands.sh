#!/usr/bin/env bash
set -euo pipefail

# A newer promotion may supersede this postsubmit before status publication.
# Ordinary presubmits still run the lifecycle, even though they skip status publication.
if [[ -e "${SHARED_DIR}/gcp-hcp-environment-status-superseded" ]]; then
  echo "Skipping HostedCluster lifecycle for a superseded promotion"
  exit 0
fi

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
for f in api-endpoint oidc-endpoint customer-project-id region; do
  if [[ ! -s "${SHARED_DIR}/${f}" ]]; then
    echo "ERROR: ${f} not found or empty in SHARED_DIR"
    echo "A workflow pre-step must write this file"
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

# Record the WIF service account for the optional authorization bootstrap.
# The INT job skips bootstrap and uses this identity for Platform API requests.
# The WIF auth step also uses it to construct wif-cred.json.
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
  echo "Configured customer project: $(cat "${SHARED_DIR}/customer-project-id")"
  echo "DNS lookup:"
  getent hosts "$(sed -E 's#https?://([^/]+)/?.*#\1#' "${SHARED_DIR}/api-endpoint")" || true
  exit 1
fi

resolve_hc_version() {
  local catalog resolved_version
  HC_VERSION_MINOR="${HC_VERSION_MINOR-5.0}"
  HC_CHANNEL_GROUP="${HC_CHANNEL_GROUP-candidate}"

  if [[ ! "${HC_VERSION_MINOR}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "ERROR: HC_VERSION_MINOR must be an exact major.minor" >&2
    return 1
  fi
  if [[ ! "${HC_CHANNEL_GROUP}" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "ERROR: HC_CHANNEL_GROUP must be a nonempty channel-group name" >&2
    return 1
  fi
  if [[ -n "${HC_VERSION:-}" && "${HC_VERSION:-}" != "${HC_VERSION_MINOR}."* ]]; then
    echo "ERROR: HC_VERSION must start with ${HC_VERSION_MINOR}." >&2
    return 1
  fi

  # Version listing uses WIF authentication but is exempt from customer namespace
  # authorization. The lifecycle's authorization bootstrap still runs in Ginkgo.
  echo "Resolving advertised HC version for ${HC_VERSION_MINOR} / ${HC_CHANNEL_GROUP}..."
  # API readiness can precede the version-sync controller's first catalog update.
  local deadline=$((SECONDS + 1200))
  local request_timeout wait_seconds
  while (( SECONDS < deadline )); do
    request_timeout=$((deadline - SECONDS))
    if (( request_timeout <= 0 )); then
      break
    fi
    if (( request_timeout > 30 )); then
      request_timeout=30
    fi
    if ! catalog="$(timeout --kill-after=5s "${request_timeout}s" /usr/bin/gcphcpctl versions list -o json)"; then
      echo "ERROR: Advertised-version request failed or timed out" >&2
      return 1
    fi

    # Retry catalogs without a match; JSON parsing/query errors fail immediately.
    if ! resolved_version="$(jq -sr \
      --arg minor "${HC_VERSION_MINOR}" \
      --arg channel "${HC_CHANNEL_GROUP}" \
      --arg exact "${HC_VERSION:-}" '
      if length == 1 and (.[0] | type == "object") and (.[0].items | type == "array")
      then .[0].items
      else error("Expected one version catalog with an items array")
      end
      | map(select(
          (.metadata.name | startswith($minor + ".")) and
          (.spec.channelGroups | index($channel) != null) and
          ($exact == "" or .metadata.name == $exact)))
      | last
      | .metadata.name // empty
    ' <<<"${catalog}")"; then
      echo "ERROR: Invalid version catalog; refusing a minor, channel, or pinned-version fallback" >&2
      return 1
    fi

    if [[ -n "${resolved_version}" ]]; then
      # Freeze the first successful selection for the entire lifecycle.
      export HC_VERSION="${resolved_version}" HC_CHANNEL_GROUP
      jq -n --arg version "${HC_VERSION}" --arg minor "${HC_VERSION_MINOR}" \
        --arg channel "${HC_CHANNEL_GROUP}" \
        '{version: $version, minor: $minor, channelGroup: $channel}' \
        > "${ARTIFACT_DIR}/hc-version-selection.json"
      return 0
    fi

    wait_seconds=$((deadline - SECONDS))
    if (( wait_seconds <= 0 )); then
      break
    fi
    if (( wait_seconds > 30 )); then
      wait_seconds=30
    fi
    echo "No matching version advertised yet; waiting ${wait_seconds}s for catalog synchronization..."
    sleep "${wait_seconds}"
  done

  echo "ERROR: No advertised version matched minor ${HC_VERSION_MINOR} / channel ${HC_CHANNEL_GROUP} / override ${HC_VERSION:-<none>} within 20 minutes" >&2
  return 1
}

resolve_hc_version

echo "Configuration:"
echo "  Customer project:   $(cat "${SHARED_DIR}/customer-project-id")"
echo "  HC minor:           ${HC_VERSION_MINOR}"
echo "  HC version:         ${HC_VERSION}"
echo "  Channel group:      ${HC_CHANNEL_GROUP}"
echo ""

# A persistent customer project is authorized once outside CI. Verify that
# access before --setup-infra can create customer-project IAM and networking.
if [[ "${GCPHCPCTL_AUTHZ_BOOTSTRAP:-true}" == "false" ]]; then
  echo "Checking pre-provisioned customer API access..."
  if ! /usr/bin/gcphcpctl cluster list -o json > /dev/null; then
    echo "ERROR: Cannot list clusters in the customer project through the Platform API"
    echo "Verify one-time customer namespace activation and a cluster-admin RoleBinding for the WIF identity outside this job"
    exit 1
  fi
fi

# The Ginkgo test reads SHARED_DIR files directly via resolveConfig().
# GCPHCPCTL_PATH points to the binary baked into the test image.
export GCPHCPCTL_PATH="/usr/bin/gcphcpctl"

# Run Ginkgo v2 test binary
echo "Running HC lifecycle validation tests..."
touch "${SHARED_DIR}/gcp-hcp-e2e-tests-started"
/usr/bin/test-e2e \
  --ginkgo.v \
  --ginkgo.no-color \
  --ginkgo.timeout=140m \
  --ginkgo.junit-report="${ARTIFACT_DIR}/junit_hc_lifecycle.xml" \
  --ginkgo.label-filter="hc-lifecycle"

echo ""
echo "HC lifecycle validation completed successfully"
touch "${SHARED_DIR}/gcp-hcp-e2e-tests-passed"
