#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [ -s "${SHARED_DIR}/cluster-id" ]; then
  CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
else
  echo "can't find file "${SHARED_DIR}/cluster-id""
fi

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

GROUP_USER=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/groups/cluster-admins/users | jq -r '.items[].id' | head -n 1)
if [[ -n ${GROUP_USER} ]];then
  echo "Delete user ${GROUP_USER} from group"
  ocm delete /api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/groups/cluster-admins/users/${GROUP_USER}
fi

IDP_ID=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers" --parameter search="type is 'HTPasswdIdentityProvider'" | jq -r '.items[].id' | head -n 1)
if [[ -n ${IDP_ID} ]];then
   echo "Delete the IDP user"
  ocm delete /api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers/${IDP_ID}
fi

