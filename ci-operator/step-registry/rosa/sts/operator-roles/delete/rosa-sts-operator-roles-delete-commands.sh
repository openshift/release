#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

retry_with_backoff() {
  local max_retries="${1}"
  shift
  local cmd=("$@")
  local attempt=1
  local rc=0
  local backoff=30

  while [[ ${attempt} -le ${max_retries} ]]; do
    echo "Attempt ${attempt}/${max_retries}: ${cmd[*]}"
    rc=0
    "${cmd[@]}" && return 0 || rc=$?
    if [[ ${attempt} -lt ${max_retries} ]]; then
      echo "Attempt ${attempt} failed (exit code ${rc}), retrying in ${backoff}s..."
      sleep ${backoff}
      backoff=$((backoff * 2))
    else
      echo "Attempt ${attempt} failed (exit code ${rc}), no more retries."
    fi
    attempt=$((attempt + 1))
  done
  return ${rc}
}

CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}

# Configure aws
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

# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

# If the byo operator roles exist, do deletion.
OPERATOR_ROLES_PREFIX_FILE="${SHARED_DIR}/cluster-prefix"
if [[ -e "${OPERATOR_ROLES_PREFIX_FILE}" ]]; then
  OPERATOR_ROLES_PREFIX=$(cat "${OPERATOR_ROLES_PREFIX_FILE}")

  echo "Start deleting the byo operator roles with the prefix ${OPERATOR_ROLES_PREFIX}..."
  set +e
  retry_with_backoff 3 rosa delete operator-roles -y --mode auto --prefix "${OPERATOR_ROLES_PREFIX}"
  ret=$?
  set -e
  if [[ ${ret} -ne 0 ]]; then
    echo "ERROR: Failed to delete operator roles after all retries (exit code ${ret})"
    exit ${ret}
  fi
else
  echo "No byo operator roles created in the pre step"
fi
echo "Finish byo operator roles deletion."
