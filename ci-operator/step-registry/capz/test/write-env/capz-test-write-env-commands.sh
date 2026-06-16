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

# Resolve MSI resource group from Boskos lease.
MSI_RESOURCEGROUPNAME="${MSI_RESOURCEGROUPNAME:-}"
if [[ -n "${LEASED_MSI_CONTAINERS:-}" && -z "${MSI_RESOURCEGROUPNAME}" ]]; then
  read -r MSI_RESOURCEGROUPNAME _ <<< "${LEASED_MSI_CONTAINERS}"
  echo "[write-env] Using pre-existing MSI from Boskos pool: ${MSI_RESOURCEGROUPNAME}"
fi

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

# Write resolved environment to SHARED_DIR (sourced by subsequent steps).
{ set +o xtrace; } 2>/dev/null
cat > "${ENV_FILE}" << ENVEOF
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
export IMAGE_PULL_SECRET_B64="${IMAGE_PULL_SECRET_B64}"
ENVEOF

chmod 600 "${ENV_FILE}"

echo "[write-env] Environment written to ${ENV_FILE}"
echo "[write-env] INFRA_PROVIDER=${INFRA_PROVIDER:-aro} CAPI_USER=${CAPI_USER:-prow} DEPLOYMENT_ENV=${DEPLOYMENT_ENV:-ci}"
echo "[write-env] REGION=${REGION:-uksouth} USE_K8S=${USE_K8S:-false} DEPLOYMENT_TIMEOUT=${DEPLOYMENT_TIMEOUT:-90m}"
echo "[write-env] ARO_REPO_URL=${ARO_REPO_URL:-https://github.com/stolostron/cluster-api-installer.git} ARO_REPO_BRANCH=${ARO_REPO_BRANCH:-main}"
echo "[write-env] NAME_PREFIX=${NAME_PREFIX} RESOURCEGROUPNAME=${RESOURCEGROUPNAME}"
