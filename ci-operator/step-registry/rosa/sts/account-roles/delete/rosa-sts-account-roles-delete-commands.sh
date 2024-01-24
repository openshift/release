#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

# Log in
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# If the account roles exist, do deletion.
ACCOUNT_ROLES_PREFIX_FILE="${SHARED_DIR}/account-roles-prefix"
if [[ -e "${ACCOUNT_ROLES_PREFIX_FILE}" ]]; then
  ACCOUNT_ROLES_PREFIX=$(cat "${ACCOUNT_ROLES_PREFIX_FILE}")

  echo "Start deleting the account roles with the prefix ${ACCOUNT_ROLES_PREFIX}..."
  rosa delete account-roles --prefix "${ACCOUNT_ROLES_PREFIX}" -y --mode auto
else
  echo "No account roles created in the pre step"
fi
echo "Finish account roles deletion."

