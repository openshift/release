#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

ACCOUNT_ROLES_PREFIX=${ACCOUNT_ROLES_PREFIX:-$NAMESPACE}
HOSTED_CP=${HOSTED_CP:-false}
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
CHANNEL_GROUP=${CHANNEL_GROUP}
PERMISSIONS_BOUNDARY=${PERMISSIONS_BOUNDARY:-}

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

# Support to create the account-roles with the higher version 
VERSION_SWITCH=""
if [[ "$CHANNEL_GROUP" != "stable" ]]; then
  if [[ -z "$OPENSHIFT_VERSION" ]]; then
    versionList=$(rosa list versions --channel-group ${CHANNEL_GROUP} -o json | jq -r '.[].raw_id')
    if [[ "$HOSTED_CP" == "true" ]]; then
      versionList=$(rosa list versions --channel-group ${CHANNEL_GROUP} --hosted-cp -o json | jq -r '.[].raw_id')
    fi
    OPENSHIFT_VERSION=$(echo "$versionList" | head -1)
  fi

  OPENSHIFT_VERSION=$(echo "${OPENSHIFT_VERSION}" | cut -d '.' -f 1,2)
  VERSION_SWITCH="--version ${OPENSHIFT_VERSION} --channel-group ${CHANNEL_GROUP}"
fi

CLUSTER_SWITCH="--classic"
if [[ "$HOSTED_CP" == "true" ]]; then
   CLUSTER_SWITCH="--hosted-cp"
fi

ARN_PATH_SWITCH=""
if [[ ! -z "$ARN_PATH" ]]; then
   ARN_PATH_SWITCH="--path ${ARN_PATH}"
fi

PERMISSIONS_BOUNDARY_SWITCH=""
if [[ ! -z "$PERMISSIONS_BOUNDARY" ]]; then
   PERMISSIONS_BOUNDARY_SWITCH="--permissions-boundary ${PERMISSIONS_BOUNDARY}"
fi

# Whatever the account roles with the prefix exist or not, do creation.
echo "Create the ${CLUSTER_SWITCH} account roles with the prefix '${ACCOUNT_ROLES_PREFIX}'"
echo "rosa create account-roles -y --mode auto --prefix ${ACCOUNT_ROLES_PREFIX} ${CLUSTER_SWITCH} ${VERSION_SWITCH} ${ARN_PATH_SWITCH}"
rosa create account-roles -y --mode auto \
                          --prefix ${ACCOUNT_ROLES_PREFIX} \
                          ${CLUSTER_SWITCH} \
                          ${VERSION_SWITCH} \
                          ${ARN_PATH_SWITCH} \
                          ${PERMISSIONS_BOUNDARY_SWITCH}

# Store the account-role-prefix for the next pre steps and the account roles deletion
echo "Store the account-role-prefix and the account-roles-arn ..."
echo -n "${ACCOUNT_ROLES_PREFIX}" > "${SHARED_DIR}/account-roles-prefix"
rosa list account-roles -o json | jq -r '.[].RoleARN' | grep "${ACCOUNT_ROLES_PREFIX}" > "${SHARED_DIR}/account-roles-arns"
