#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

OPERATOR_ROLES_PREFIX=$(head -n 1 "${SHARED_DIR}/cluster-prefix")
OIDC_CONFIG_MANAGED=${OIDC_CONFIG_MANAGED:-true}
CHANNEL_GROUP=${CHANNEL_GROUP:-"stable"}

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
AWS_ACCOUNT_ID=$(rosa whoami --output json | jq -r '."AWS Account ID"')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

# Switches
account_installer_role_arn=$(cat "${SHARED_DIR}/account-roles-arns" | { grep "Installer-Role" || true; })
oidc_config_id=$(cat "${SHARED_DIR}/oidc-config" | jq -r '.id')

HOSTED_CP_SWITCH=""
if [[ "$HOSTED_CP" == "true" ]]; then
  HOSTED_CP_SWITCH="--hosted-cp"
fi

SHARED_VPC_SWITCH=""
if [[ "$ENABLE_SHARED_VPC" == "yes" ]]; then
  shared_vpc_role_arn=$(cat "${SHARED_DIR}/hosted_zone_role_arn")
  SHARED_VPC_SWITCH="--shared-vpc-role-arn ${shared_vpc_role_arn}"
fi

# Create operator roles
echo "Create the operator roles with the prefix ${OPERATOR_ROLES_PREFIX}..."
rosa create operator-roles -y --mode auto \
                           --prefix ${OPERATOR_ROLES_PREFIX} \
                           --oidc-config-id ${oidc_config_id} \
                           --installer-role-arn ${account_installer_role_arn} \
                           --channel-group ${CHANNEL_GROUP} \
                           ${HOSTED_CP_SWITCH} \
                           ${SHARED_VPC_SWITCH} \
                           | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"
# rosa list operator-roles --prefix ${OPERATOR_ROLES_PREFIX} --output json > "${SHARED_DIR}/operator-roles-arns"
ret=0
rosa list operator-roles --prefix ${OPERATOR_ROLES_PREFIX} |grep -v OPERATOR | awk '{print $4}' > "${SHARED_DIR}/operator-roles-arns" || ret=$?
if [[ "$ret" != 0 ]]; then
    rosa list operator-roles --prefix ${OPERATOR_ROLES_PREFIX} |grep -v OPERATOR | awk '{print $4}' > "${SHARED_DIR}/operator-roles-arns"
fi
echo "Storing successfully"
