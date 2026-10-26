#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${SHARED_DIR}/capz-test-env.sh"

{ set +o xtrace; } 2>/dev/null

# Resolve Azure credentials from mounted secrets.
AZURE_CLIENT_ID=""
AZURE_CLIENT_SECRET=""
AZURE_TENANT_ID=""
AZURE_SUBSCRIPTION_ID=""

if [[ -n "${VAULT_SECRET_PROFILE:-}" && -d "/var/run/aro-hcp-${VAULT_SECRET_PROFILE}" ]]; then
  CRED_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"
  AZURE_CLIENT_ID="$(cat "${CRED_DIR}/client-id")"
  AZURE_CLIENT_SECRET="$(cat "${CRED_DIR}/client-secret")"
  AZURE_TENANT_ID="$(cat "${CRED_DIR}/tenant")"
  AZURE_SUBSCRIPTION_ID="$(cat "${CRED_DIR}/subscription-id")"
  echo "[write-env] Credentials resolved from ${CRED_DIR}"
elif [[ -n "${CLUSTER_PROFILE_DIR:-}" && -f "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json" ]]; then
  AZURE_CLIENT_ID=$(jq -r .clientId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
  AZURE_CLIENT_SECRET=$(jq -r .clientSecret "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
  AZURE_TENANT_ID=$(jq -r .tenantId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
  AZURE_SUBSCRIPTION_ID=$(jq -r .subscriptionId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
  echo "[write-env] Credentials resolved from ${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
fi

CAPZ_CREDS_DIR="/var/run/capz-azure-credentials"
if [[ -d "${CAPZ_CREDS_DIR}" && -f "${CAPZ_CREDS_DIR}/AZURE_CLIENT_ID" ]]; then
  AZURE_CLIENT_ID=$(cat "${CAPZ_CREDS_DIR}/AZURE_CLIENT_ID")
  AZURE_CLIENT_SECRET=$(cat "${CAPZ_CREDS_DIR}/AZURE_CLIENT_SECRET")
  AZURE_TENANT_ID=$(cat "${CAPZ_CREDS_DIR}/AZURE_TENANT_ID")
  AZURE_SUBSCRIPTION_ID=$(cat "${CAPZ_CREDS_DIR}/AZURE_SUBSCRIPTION_ID")
  echo "[write-env] Credentials overridden from ${CAPZ_CREDS_DIR}"
fi

for var in AZURE_CLIENT_ID AZURE_CLIENT_SECRET AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID; do
  val="${!var}"
  if [[ -z "${val}" || "${val}" == "null" ]]; then
    echo "[write-env] ERROR: ${var} is missing or null" >&2
    exit 1
  fi
done

# Generate stable identifiers for this job run.
NAME_PREFIX_FILE="${SHARED_DIR}/name-prefix"
if [[ -f "$NAME_PREFIX_FILE" ]]; then
  NAME_PREFIX=$(cat "$NAME_PREFIX_FILE")
else
  NAME_PREFIX="capz-$(openssl rand -hex 3)"
  echo "$NAME_PREFIX" > "$NAME_PREFIX_FILE"
fi

RESOURCEGROUPNAME_FILE="${SHARED_DIR}/resource-group-name"
if [[ -f "$RESOURCEGROUPNAME_FILE" ]]; then
  RESOURCEGROUPNAME="$(cat "$RESOURCEGROUPNAME_FILE")"
else
  RESOURCEGROUPNAME="capz-tests-$(openssl rand -hex 3)-resgroup"
  echo "$RESOURCEGROUPNAME" > "$RESOURCEGROUPNAME_FILE"
fi

# Source slot-manager runtime contract if available (DEV path).
SLOT_ENV_FILE="${SHARED_DIR}/aro-hcp-slot.env"
if [[ -f "${SLOT_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${SLOT_ENV_FILE}"
  echo "[write-env] Sourced slot-manager env from ${SLOT_ENV_FILE}"
  if [[ -n "${CUSTOMER_SUBSCRIPTION:-}" ]]; then
    # CUSTOMER_SUBSCRIPTION is a subscription name; resolve to UUID via vault profile files.
    CRED_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"
    RESOLVED_SUB_ID=""
    for name_file in "${CRED_DIR}"/customer-*-subscription-name; do
      [[ -f "${name_file}" ]] || continue
      if [[ "$(cat "${name_file}")" == "${CUSTOMER_SUBSCRIPTION}" ]]; then
        id_file="${name_file%-subscription-name}-subscription-id"
        if [[ -f "${id_file}" ]]; then
          RESOLVED_SUB_ID="$(cat "${id_file}")"
        fi
        break
      fi
    done
    if [[ -n "${RESOLVED_SUB_ID}" ]]; then
      AZURE_SUBSCRIPTION_ID="${RESOLVED_SUB_ID}"
      echo "[write-env] AZURE_SUBSCRIPTION_ID resolved from CUSTOMER_SUBSCRIPTION"
    else
      echo "[write-env] ERROR: Could not resolve subscription ID for CUSTOMER_SUBSCRIPTION" >&2
      exit 1
    fi
  fi
fi

# Resolve MSI resource group from LEASED_MSI_CONTAINERS (slot-manager or ci-operator lease).
MSI_SUFFIX=""
MSI_RESOURCEGROUPNAME="${MSI_RESOURCEGROUPNAME:-}"
if [[ -n "${LEASED_MSI_CONTAINERS:-}" && -z "${MSI_RESOURCEGROUPNAME}" ]]; then
  read -r MSI_RESOURCEGROUPNAME _ <<< "${LEASED_MSI_CONTAINERS}"
  # Extract MSI_SUFFIX from slot-managed container RG name
  # (e.g. aro-hcp-msi-container-dev-shard0-04-00 → shard0-04-00).
  if [[ "$MSI_RESOURCEGROUPNAME" =~ ^aro-hcp-msi-container-[a-z]+-(.+)$ ]]; then
    MSI_SUFFIX="${BASH_REMATCH[1]}"
  fi
  echo "[write-env] Using pre-existing MSI from Boskos pool: ${MSI_RESOURCEGROUPNAME}"
fi

# Resolve REGION for HCP cluster (not SELECTED_LOCATION — MSI containers
# may be in a region that doesn't support HCPOpenShiftClusters).
REGION="${LOCATION:-uksouth}"
# MSI_REGION is where MSI containers live (from slot-manager or same as REGION).
MSI_REGION="${SELECTED_LOCATION:-${REGION}}"

# Resolve GOCACHE.
GOCACHE="${GOCACHE:-/tmp/go-cache}"
if [[ ! -d "${GOCACHE}" ]] || [[ ! -w "${GOCACHE}" ]]; then
  GOCACHE=/tmp/go-cache
fi

# Resolve USE_KUBECONFIG.
USE_KUBECONFIG="${USE_KUBECONFIG:-}"
if [[ -n "${SHARED_DIR:-}" && -z "${USE_KUBECONFIG}" ]]; then
  USE_KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

# Resolve quay pull secret.
QUAY_CREDS_FILE="/etc/quay-pull-credentials/.dockerconfigjson"
IMAGE_PULL_SECRET_B64=""
if [[ -f "${QUAY_CREDS_FILE}" ]]; then
  IMAGE_PULL_SECRET_B64=$(base64 -w0 < "${QUAY_CREDS_FILE}")
  echo "[write-env] Quay pull secret resolved"
fi

# Validate and fingerprint the mounted Quay credential. Never log credential
# values, parser errors, or fingerprints; SHARED_DIR is not a public artifact.
QUAY_AUTH_DIAGNOSTICS=false
if [[ -n "${QUAY_AUTH_EXPECTED_SHA256:-}" ]]; then
  QUAY_AUTH_DIAGNOSTICS=true
  if ! jq -e '.auths["quay.io"].auth | strings | @base64d | test("^[^:]+:.+$")' \
    "${QUAY_CREDS_FILE}" >/dev/null 2>&1; then
    echo "[quay-diag] Mounted Quay credential structure: INVALID (expected nonempty username:token)"
    exit 1
  fi
  QUAY_AUTH_SHA256=$(jq -jr '.auths["quay.io"].auth | @base64d' "${QUAY_CREDS_FILE}" | sha256sum | cut -d ' ' -f 1)
  echo "[quay-diag] Mounted Quay credential structure: VALID"
  if [[ "${QUAY_AUTH_SHA256}" != "${QUAY_AUTH_EXPECTED_SHA256}" ]]; then
    echo "[quay-diag] Tested Vault download → Prow mount: MISMATCH (informational)"
    quay_source_metadata() {
      # Use the CI pod's in-cluster identity, not the future AKS kubeconfig.
      # Reading metadata is best effort and never changes RBAC or secrets.
      if [[ -z "${NAMESPACE:-}" || -z "${HOSTNAME:-}" ]]; then
        echo "[quay-diag] Source metadata: UNAVAILABLE (no CI pod identity)"
        return
      fi
      ci_oc() {
        env -u KUBECONFIG -u KUBECONFIGMINIMAL oc --request-timeout=5s -n "${NAMESPACE}" "$@"
      }
      local pod_json volume_name spc_name spc_json provider statuses_json versions
      if ! pod_json=$(ci_oc get pod "${HOSTNAME}" -o json 2>/dev/null); then
        echo "[quay-diag] Source metadata: UNAVAILABLE (cannot read CI pod)"
        return
      fi
      if ! volume_name=$(printf '%s' "${pod_json}" | jq -er '
        first(.spec.containers[] | select(.name == "test") | .volumeMounts[] |
          select(.mountPath == "/etc/quay-pull-credentials") | .name)' 2>/dev/null) ||
        ! spc_name=$(printf '%s' "${pod_json}" | jq -er --arg volume "${volume_name}" '
        .spec.volumes[] | select(.name == $volume) |
          .csi.volumeAttributes.secretProviderClass' 2>/dev/null); then
        echo "[quay-diag] Source metadata: UNAVAILABLE (no CSI mount mapping)"
        return
      fi
      if ! spc_json=$(ci_oc get secretproviderclass "${spc_name}" -o json 2>/dev/null); then
        echo "[quay-diag] Source metadata: UNAVAILABLE (cannot read SecretProviderClass; check CI RBAC)"
        return
      fi
      provider=$(printf '%s' "${spc_json}" | jq -r '.spec.provider // "unknown"')
      case "${provider}" in
        gcp|vault|azure|aws) echo "[quay-diag] CSI provider: ${provider}" ;;
        *) echo "[quay-diag] CSI provider: OTHER OR UNKNOWN" ;;
      esac
      # GCP's mapping is YAML embedded in JSON. Print only validated resource
      # identifiers and file names, never the complete parameters or payload.
      printf '%s' "${spc_json}" | jq -r '.spec.parameters.secrets // ""' | sed -nE \
        -e 's/^[[:space:]-]*resourceName:[[:space:]]*"?(projects\/[[:alnum:]_-]+\/secrets\/[[:alnum:]_-]+\/versions\/(latest|[0-9]+))"?[[:space:]]*$/[quay-diag] GSM source resource: \1/p' \
        -e 's/^[[:space:]-]*fileName:[[:space:]]*"?([[:alnum:]_.-]+)"?[[:space:]]*$/[quay-diag] Mounted source field: \1/p'
      if ! statuses_json=$(ci_oc get secretproviderclasspodstatuses -o json 2>/dev/null); then
        echo "[quay-diag] Resolved GSM version: UNAVAILABLE (cannot read CSI pod status)"
        return
      fi
      versions=$(printf '%s' "${statuses_json}" | jq -r --arg pod "${HOSTNAME}" --arg spc "${spc_name}" '
        .items[] | select(.status.podName == $pod and .status.secretProviderClassName == $spc) |
        .status.objects[]? | select(.id | test("^projects/[A-Za-z0-9_-]+/secrets/[A-Za-z0-9_-]+/versions/(latest|[0-9]+)$")) |
        (.version | tostring | capture("^(?:projects/[A-Za-z0-9_-]+/secrets/[A-Za-z0-9_-]+/versions/)?(?<number>[0-9]+)$").number) as $version |
        "[quay-diag] Resolved GSM version: \($version) for \(.id)"' 2>/dev/null)
      if [[ -n "${versions}" ]]; then
        printf '%s\n' "${versions}"
      else
        echo "[quay-diag] Resolved GSM version: UNAVAILABLE (no numeric version in CSI status)"
      fi
    }
    quay_source_metadata 2>/dev/null || echo "[quay-diag] Source metadata: UNAVAILABLE (lookup failed)"

    # A rotated sibling field can differ from an unchanged .dockerconfigjson.
    # Report comparisons only; these files are never copied into artifacts.
    for sibling in auth acm_d_mce_quay_username acm_d_mce_quay_pullsecret; do
      sibling_file="${QUAY_CREDS_FILE%/*}/${sibling}"
      case "${sibling}" in
        auth) sibling_label="auth decoded pair"; sibling_expected="${QUAY_AUTH_EXPECTED_SHA256}" ;;
        acm_d_mce_quay_username) sibling_label="username"; sibling_expected="${QUAY_USERNAME_EXPECTED_SHA256:-}" ;;
        acm_d_mce_quay_pullsecret) sibling_label="token"; sibling_expected="${QUAY_TOKEN_EXPECTED_SHA256:-}" ;;
      esac
      if [[ ! -r "${sibling_file}" || -z "${sibling_expected}" ]]; then
        echo "[quay-diag] Sibling ${sibling_label} vs known-good: NOT AVAILABLE"
        continue
      fi
      if [[ "${sibling}" == "auth" ]]; then
        if ! sibling_sha256=$(base64 --decode < "${sibling_file}" 2>/dev/null | sha256sum | cut -d ' ' -f 1); then
          echo "[quay-diag] Sibling ${sibling_label} vs known-good: INVALID BASE64"
          continue
        fi
      else
        sibling_sha256=$(sha256sum < "${sibling_file}" | cut -d ' ' -f 1)
      fi
      if [[ "${sibling_sha256}" == "${sibling_expected}" ]]; then
        echo "[quay-diag] Sibling ${sibling_label} vs known-good: MATCH"
      else
        echo "[quay-diag] Sibling ${sibling_label} vs known-good: MISMATCH"
      fi
    done

    # Stream decoded components through pipes so command substitution cannot
    # remove trailing newlines. Compare only; never repair or log credentials.
    quay_component() {
      jq -jr --arg component "$1" '
        .auths["quay.io"].auth | @base64d |
        if $component == "username" then split(":")[0]
        else sub("^[^:]*:"; "") end
      ' "${QUAY_CREDS_FILE}"
    }
    for component in username token; do
      if [[ "${component}" == "username" ]]; then
        expected_component_sha256="${QUAY_USERNAME_EXPECTED_SHA256:-}"
      else
        expected_component_sha256="${QUAY_TOKEN_EXPECTED_SHA256:-}"
      fi
      if quay_component "${component}" | jq -eRs 'test("^\\s|\\s$")' >/dev/null; then
        echo "[quay-diag] ${component} leading/trailing whitespace: YES"
      else
        echo "[quay-diag] ${component} leading/trailing whitespace: NO"
      fi
      if [[ -z "${expected_component_sha256}" ]]; then
        echo "[quay-diag] ${component} vs known-good: NOT CHECKED (no reference supplied)"
        continue
      fi
      component_sha256=$(quay_component "${component}" | sha256sum | cut -d ' ' -f 1)
      if [[ "${component_sha256}" == "${expected_component_sha256}" ]]; then
        echo "[quay-diag] ${component} vs known-good: MATCH"
      else
        echo "[quay-diag] ${component} vs known-good: MISMATCH"
      fi
      trimmed_sha256=$(quay_component "${component}" | jq -jRs 'gsub("^\\s+|\\s+$"; "")' | sha256sum | cut -d ' ' -f 1)
      if [[ "${trimmed_sha256}" == "${expected_component_sha256}" ]]; then
        echo "[quay-diag] ${component} after trimming whitespace vs known-good: MATCH"
      else
        echo "[quay-diag] ${component} after trimming whitespace vs known-good: MISMATCH"
      fi
    done
  else
    echo "[quay-diag] Tested Vault download → Prow mount: MATCH"
  fi
  # Downstream checks compare the actual mounted value, even if it differs
  # from our locally tested reference. A different credential may still work.
  (umask 077; printf '%s\n' "${QUAY_AUTH_SHA256}" > "${SHARED_DIR}/quay-auth.sha256")

  probe_quay_images() {
    if [[ -z "${QUAY_DIAGNOSTIC_IMAGES:-}" ]]; then
      echo "[quay-diag] Manifest access checks: NOT REQUESTED"
      return 0
    fi
    local error_file image status category failed=0
    error_file=$(mktemp "${SHARED_DIR}/quay-image-probe.XXXXXX")
    # The private error file is never copied into ARTIFACT_DIR. Neither stdout
    # nor raw registry errors are logged; even failed responses can hold secrets.
    for image in ${QUAY_DIAGNOSTIC_IMAGES}; do
      if [[ ! "${image}" =~ ^quay[.]io/[a-z0-9._/-]+(:[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})$ ]]; then
        echo "[quay-diag] Manifest access: INVALID IMAGE REFERENCE"
        failed=1
        continue
      fi
      status=0
      timeout 25s oc image info --registry-config "${QUAY_CREDS_FILE}" \
        --filter-by-os=linux/amd64 --output=json "${image}" \
        >/dev/null 2>"${error_file}" || status=$?
      if [[ "${status}" -eq 0 ]]; then
        echo "[quay-diag] ${image} manifest access: SUCCESS"
        continue
      fi
      failed=1
      if [[ "${status}" -eq 124 ]]; then
        category="TIMEOUT"
      elif grep -Eiq 'too many requests|rate.?limit' "${error_file}"; then
        category="RATE LIMITED"
      elif grep -Eiq 'unauthorized|authentication required|invalid username/password|no basic auth credentials' "${error_file}"; then
        category="AUTHENTICATION REJECTED"
      elif grep -Eiq 'forbidden|denied' "${error_file}"; then
        category="ACCESS DENIED"
      elif grep -Eiq 'manifest unknown|name unknown|not found' "${error_file}"; then
        category="IMAGE OR TAG NOT FOUND"
      elif grep -Eiq 'no such host|temporary failure in name resolution' "${error_file}"; then
        category="DNS FAILURE"
      elif grep -Eiq 'x509|certificate verify|tls handshake' "${error_file}"; then
        category="TLS FAILURE"
      elif grep -Eiq 'timed out|timeout|deadline exceeded' "${error_file}"; then
        category="TIMEOUT"
      elif grep -Eiq 'connection refused|network is unreachable|connection reset' "${error_file}"; then
        category="NETWORK FAILURE"
      else
        category="UNCLASSIFIED ERROR"
      fi
      echo "[quay-diag] ${image} manifest access: ${category}"
    done
    rm -f "${error_file}"
    return "${failed}"
  }
fi

# Write resolved environment to SHARED_DIR (sourced by subsequent steps).
{ set +o xtrace; } 2>/dev/null
cat > "${ENV_FILE}" << ENVEOF
{ set +o xtrace; } 2>/dev/null
export AZURE_CLIENT_ID="${AZURE_CLIENT_ID}"
export AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET}"
export AZURE_TENANT_ID="${AZURE_TENANT_ID}"
export AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID}"
export GOCACHE="${GOCACHE}"
export INFRA_PROVIDER="${INFRA_PROVIDER:-aro}"
export CAPI_USER="${CAPI_USER:-prow}"
export DEPLOYMENT_ENV="${DEPLOYMENT_ENV:-ci}"
export REGION="${REGION:-uksouth}"
export OPERATORS_UAMIS_SUFFIX_FILE="${OPERATORS_UAMIS_SUFFIX_FILE:-/tmp/operators-uamis-suffix.txt}"
export ARO_REPO_URL="${ARO_REPO_URL:-https://github.com/stolostron/cluster-api-installer.git}"
export ARO_REPO_BRANCH="${ARO_REPO_BRANCH:-main}"
export ARO_REPO_DIR="${ARO_REPO_DIR:-/tmp/cluster-api-installer-pro}"
export USE_KUBECONFIG="${USE_KUBECONFIG}"
export USE_K8S="${USE_K8S:-false}"
export DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-90m}"
export NAME_PREFIX="${NAME_PREFIX}"
export RESOURCEGROUPNAME="${RESOURCEGROUPNAME}"
export MSI_RESOURCEGROUPNAME="${MSI_RESOURCEGROUPNAME}"
export MSI_SUFFIX="${MSI_SUFFIX}"
export MSI_REGION="${MSI_REGION}"
export IMAGE_PULL_SECRET_B64="${IMAGE_PULL_SECRET_B64}"
export QUAY_AUTH_DIAGNOSTICS="${QUAY_AUTH_DIAGNOSTICS}"
ENVEOF

chmod 600 "${ENV_FILE}"

echo "[write-env] Environment written to ${ENV_FILE}"
echo "[write-env] INFRA_PROVIDER=${INFRA_PROVIDER:-aro} CAPI_USER=${CAPI_USER:-prow} DEPLOYMENT_ENV=${DEPLOYMENT_ENV:-ci}"
echo "[write-env] REGION=${REGION:-uksouth} USE_K8S=${USE_K8S:-false} DEPLOYMENT_TIMEOUT=${DEPLOYMENT_TIMEOUT:-90m}"
echo "[write-env] ARO_REPO_URL=${ARO_REPO_URL:-https://github.com/stolostron/cluster-api-installer.git} ARO_REPO_BRANCH=${ARO_REPO_BRANCH:-main}"
echo "[write-env] NAME_PREFIX=${NAME_PREFIX} RESOURCEGROUPNAME=${RESOURCEGROUPNAME}"
echo "[write-env] MSI_RESOURCEGROUPNAME=${MSI_RESOURCEGROUPNAME} MSI_SUFFIX=${MSI_SUFFIX} MSI_REGION=${MSI_REGION}"

# Write the shared environment first so post steps can still initialize if the
# registry check fails. Successful checks permit provisioning and AKS diagnostics.
if [[ "${QUAY_AUTH_DIAGNOSTICS}" == "true" ]]; then
  probe_quay_images
fi
