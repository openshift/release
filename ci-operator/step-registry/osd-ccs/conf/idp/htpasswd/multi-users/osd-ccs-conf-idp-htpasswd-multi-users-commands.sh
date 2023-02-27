#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

# Get the HTPasswd IDP ID
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
IDP_ID=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers" --parameter search="type is 'HTPasswdIdentityProvider'" | jq -r '.items[].id' | head -n 1)

# Generate mulitple users 
echo "Generate the mulitple users under the htpasswd idp ..."
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
