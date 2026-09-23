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

WIF_CONFIG_ID=$(cat "${SHARED_DIR}/wif-config-id" 2>/dev/null || true)
if [[ -z "${WIF_CONFIG_ID}" ]]; then
  logger "INFO" "No WIF config ID found in SHARED_DIR, skipping deletion"
  exit 0
fi

logger "INFO" "Deleting WIF config: ${WIF_CONFIG_ID}"
ocm gcp delete wif-config "${WIF_CONFIG_ID}"
logger "INFO" "WIF config ${WIF_CONFIG_ID} deleted successfully"
