#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Retry wrapper with exponential backoff for transient DNS resolution failures
# on CI build clusters (e.g. build01 CoreDNS flakes against api.stage.openshift.com).
# Usage: retry_with_backoff "command to run"
retry_with_backoff() {
  local cmd="${1}"
  local max_attempts=5
  local delay=10
  local attempt=1

  while true; do
    echo "Attempt ${attempt}/${max_attempts}: ${cmd}" >&2
    if eval "${cmd}"; then
      return 0
    fi
    if [[ ${attempt} -ge ${max_attempts} ]]; then
      echo "ERROR: All ${max_attempts} attempts exhausted for: ${cmd}" >&2
      capture_dns_diagnostics
      return 1
    fi
    echo "Attempt ${attempt} failed. Retrying in ${delay}s ..." >&2
    sleep "${delay}"
    delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# Capture DNS diagnostic information when OCM API calls fail.
# Helps distinguish CI infrastructure DNS issues from genuine API outages.
capture_dns_diagnostics() {
  local ocm_host="${OCM_LOGIN_ENV:-staging}"
  # Map OCM env names to hostnames for diagnostics
  case "${ocm_host}" in
    production|prod) ocm_host="api.openshift.com" ;;
    staging|stage)   ocm_host="api.stage.openshift.com" ;;
    integration|int) ocm_host="api.integration.openshift.com" ;;
    *)               ocm_host="api.stage.openshift.com" ;;
  esac

  echo "=== DNS Diagnostics (target: ${ocm_host}) ===" >&2
  echo "--- dig ${ocm_host} ---" >&2
  dig "${ocm_host}" >&2 2>&1 || true
  echo "--- /etc/resolv.conf ---" >&2
  cat /etc/resolv.conf >&2 2>&1 || true
  echo "--- nslookup ${ocm_host} 172.30.0.10 (cluster DNS) ---" >&2
  nslookup "${ocm_host}" 172.30.0.10 >&2 2>&1 || true
  echo "=== End DNS Diagnostics ===" >&2
}

OIDC_CONFIG_PREFIX=$(head -n 1 "${SHARED_DIR}/cluster-prefix")
OIDC_CONFIG_MANAGED=${OIDC_CONFIG_MANAGED:-true}

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}


# Log in with retry logic to handle transient DNS failures on CI build clusters
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  retry_with_backoff "rosa login --env '${OCM_LOGIN_ENV}' --client-id '${SSO_CLIENT_ID}' --client-secret '${SSO_CLIENT_SECRET}'"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  retry_with_backoff "rosa login --env '${OCM_LOGIN_ENV}' --token '${ROSA_TOKEN}'"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi
AWS_ACCOUNT_ID=$(retry_with_backoff "rosa whoami --output json" | jq -r '."AWS Account ID"')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

# Switches
MANAGED_SWITCH="--managed=${OIDC_CONFIG_MANAGED}"
if [[ "$OIDC_CONFIG_MANAGED" == "false" ]]; then
  account_installer_role_arn=$(cat "${SHARED_DIR}/account-roles-arns" | { grep "Installer-Role" || true; })  
  MANAGED_SWITCH="${MANAGED_SWITCH} --prefix ${OIDC_CONFIG_PREFIX} --installer-role-arn ${account_installer_role_arn}"
fi

# Create oidc config
echo "Create the managed=${OIDC_CONFIG_MANAGED} oidc config ${OIDC_CONFIG_PREFIX} ..."
rosa create oidc-config -y --mode auto --output json\
                        ${MANAGED_SWITCH} \
                        > "${SHARED_DIR}/oidc-config"
echo "Successfully create the oidc config."
oidc_config_id=$(cat "${SHARED_DIR}/oidc-config" | jq -r '.id')

# Create oidc provider
echo "Create the oidc provider based on the byo oic config ..."
rosa create oidc-provider -y --mode auto --oidc-config-id $oidc_config_id | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"
echo "Successfully create the oidc provider."
