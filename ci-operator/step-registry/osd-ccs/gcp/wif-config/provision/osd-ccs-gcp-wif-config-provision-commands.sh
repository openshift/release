#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function logger() {
  local -r log_level=$1; shift
  local -r log_msg=$1; shift
  echo "$(date -u --rfc-3339=seconds) - ${log_level}: ${log_msg}"
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

GCP_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/osd-ccs-gcp.json"
export GOOGLE_APPLICATION_CREDENTIALS="${GCP_CREDENTIALS_FILE}"

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
if [[ -n "${OCM_TOKEN}" ]]; then
  logger "INFO" "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
elif [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  logger "INFO" "Logging into ${OCM_LOGIN_ENV} with SSO credentials using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
else
  logger "ERROR" "Cannot login! You need to securely supply an ocm-token or SSO credentials!"
  exit 1
fi

# Determine GCP project ID
if [[ -z "${GCP_PROJECT_ID}" ]]; then
  GCP_PROJECT_ID=$(jq -r '.project_id' "${GCP_CREDENTIALS_FILE}")
  logger "INFO" "Extracted GCP project ID from credentials: ${GCP_PROJECT_ID}"
fi

# Generate WIF config name if not provided
suffix=$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)
WIF_CONFIG_NAME=${WIF_CONFIG_NAME:-"ci-wif-$suffix"}

logger "INFO" "Creating WIF config:"
echo "  Name: ${WIF_CONFIG_NAME}"
echo "  GCP project ID: ${GCP_PROJECT_ID}"

ocm gcp create wif-config --name "${WIF_CONFIG_NAME}" --project "${GCP_PROJECT_ID}" > "${ARTIFACT_DIR}/wif-config.txt"

WIF_CONFIG_ID=$(ocm gcp describe wif-config "${WIF_CONFIG_NAME}" | grep ID | awk '{print $2}')
if [[ -z "${WIF_CONFIG_ID}" ]]; then
  logger "ERROR" "Failed to retrieve WIF config ID"
  exit 1
fi

logger "INFO" "WIF config created: ${WIF_CONFIG_ID}"
echo -n "${WIF_CONFIG_ID}" > "${SHARED_DIR}/wif-config-id"
echo -n "${WIF_CONFIG_NAME}" > "${SHARED_DIR}/wif-config-name"
