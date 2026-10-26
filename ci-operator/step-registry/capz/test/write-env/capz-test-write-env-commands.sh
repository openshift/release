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
    echo "[quay-diag] Mounted Quay credential: INVALID (expected nonempty username:token)"
    exit 1
  fi
  QUAY_AUTH_SHA256=$(jq -jr '.auths["quay.io"].auth | @base64d' "${QUAY_CREDS_FILE}" | sha256sum | cut -d ' ' -f 1)
  echo "[quay-diag] Mounted Quay credential: VALID"
  if [[ "${QUAY_AUTH_SHA256}" != "${QUAY_AUTH_EXPECTED_SHA256}" ]]; then
    echo "[quay-diag] Known-good Vault credential → Prow mount: MISMATCH"
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
    exit 1
  fi
  echo "[quay-diag] Known-good Vault credential → Prow mount: MATCH"
  (umask 077; printf '%s\n' "${QUAY_AUTH_SHA256}" > "${SHARED_DIR}/quay-auth.sha256")
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
