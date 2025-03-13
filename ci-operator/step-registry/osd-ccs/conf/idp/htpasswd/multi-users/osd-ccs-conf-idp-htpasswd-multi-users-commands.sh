#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Log in
OCM_VERSION=$(ocm version)
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

# Get the HTPasswd IDP ID
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
IDP_ID=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers" --parameter search="type is 'HTPasswdIdentityProvider'" | jq -r '.items[].id' | head -n 1)
IDP_INFO=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers/${IDP_ID}")
# Generate mulitple users 
echo "Generate the mulitple users under ${IDP_INFO} the htpasswd idp ..."
users=""
for i in $(seq 1 ${USER_COUNT});
do
  username="testuser-${i}"
  password="HTPasswd_$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)"
  users+="${username}:${password},"
  payload=$(echo -e '{
    "username": "'${username}'",
    "password": "'${password}'"
  }')

  echo "Adding user ${username}"
  echo "${payload}" | jq -c | ocm post "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers/${IDP_ID}/htpasswd_users"
done

# Store users in a shared file
echo "export USERS=${users}" > "${SHARED_DIR}/runtime_env"
