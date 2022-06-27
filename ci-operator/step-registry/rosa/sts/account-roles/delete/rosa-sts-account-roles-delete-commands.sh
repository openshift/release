#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

ACCOUNT_ROLES_PREFIX=${ACCOUNT_ROLES_PREFIX:-"ManagedOpenshift"}
CLOUD_PROVIDER_REGION=${CLOUD_PROVIDER_REGION:-"us-east-2"}

# Configure aws
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  AWS_ACCESS_KEY_ID=$(cat "${AWSCRED}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_SECRET_ACCESS_KEY=$(cat "${AWSCRED}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)

  aws configure set aws_access_key_id  ${AWS_ACCESS_KEY_ID}
  aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
  aws configure set default.region ${CLOUD_PROVIDER_REGION}
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${ROSA_LOGIN_ENV} with offline token"
  rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# If the account roles exist, do deletion.
echo "Validate whether the account roles with the prefix '${ACCOUNT_ROLES_PREFIX}' exist"
Account_Installer_Role_Name="${ACCOUNT_ROLES_PREFIX}-Installer-Role"
Account_Installer_Role_ARN=$(rosa list account-roles -o json | jq -r '.[].RoleARN' | { grep "${Account_Installer_Role_Name}" || true; })
if [[ -z "${Account_Installer_Role_ARN}" ]]; then 
  echo "No account roles with the prefix '${ACCOUNT_ROLES_PREFIX}' exist"
else
  echo "Delete the account roles with the prefix ${ACCOUNT_ROLES_PREFIX}"
  rosa delete account-roles --prefix "${ACCOUNT_ROLES_PREFIX}" -y --mode auto
fi
