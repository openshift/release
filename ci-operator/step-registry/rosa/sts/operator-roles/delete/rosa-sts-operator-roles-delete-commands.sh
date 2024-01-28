#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

# If the byo operator roles exist, do deletion.
OPERATOR_ROLES_PREFIX_FILE="${SHARED_DIR}/operator-roles-prefix"
if [[ -e "${OPERATOR_ROLES_PREFIX_FILE}" ]]; then
  OPERATOR_ROLES_PREFIX=$(cat "${OPERATOR_ROLES_PREFIX_FILE}")

  echo "Start deleting the byo operator roles with the prefix ${OPERATOR_ROLES_PREFIX}..."
  rosa delete operator-roles -y --mode auto --prefix ${OPERATOR_ROLES_PREFIX}
else
  echo "No byo operator roles created in the pre step"
fi
echo "Finish byo operator roles deletion."
