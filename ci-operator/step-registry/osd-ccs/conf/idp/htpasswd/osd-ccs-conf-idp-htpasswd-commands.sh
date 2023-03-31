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

# Config htpasswd idp
# The expected time for the htpasswd idp configuaration is in 1 minute. But actually, we met the waiting time
# is over 10 minutes, so we give a loop to wait for the configuration to be active before timeout. 
echo "Config htpasswd idp ..."
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
IDP_NAME="osd-htpasswd"
IDP_USER="osd-admin"
IDP_PASSWD="HTPasswd_$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)"
IDP_PAYLOAD=$(echo -e '{
  "kind": "IdentityProvider",
  "htpasswd": {
    "users": {
      "items": [
        {
          "username": "'${IDP_USER}'",
          "password": "'${IDP_PASSWD}'"
        }
      ]
    }
  },
  "name": "'${IDP_NAME}'",
  "type": "HTPasswdIdentityProvider"  
}')
echo "${IDP_PAYLOAD}" | jq -c | ocm post "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/identity_providers"  > "${SHARED_DIR}/htpasswd.txt"

API_URL=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" | jq -r ".api.url")
echo "oc login ${API_URL} -u ${IDP_USER} -p ${IDP_PASSWD} --insecure-skip-tls-verify=true" > "${SHARED_DIR}/api.login"
cat "${SHARED_DIR}/api.login" > "${ARTIFACT_DIR}/api.login"

# Grant cluster-admin access to the cluster
echo "Add the user ${IDP_USER} to the cluster-admins group..."
ocm create user ${IDP_USER} --cluster=${CLUSTER_ID} --group=cluster-admins

echo "Waiting for idp ready..."
IDP_LOGIN_LOG="${ARTIFACT_DIR}/htpasswd_login.log"
start_time=$(date +"%s")
while true; do
  sleep 60
  echo "Attempt to login..."
  oc login ${API_URL} -u ${IDP_USER} -p ${IDP_PASSWD} --insecure-skip-tls-verify=true > "${IDP_LOGIN_LOG}" || true
  LOGIN_INFO=$(cat "${IDP_LOGIN_LOG}")
  if [[ "${LOGIN_INFO}" =~ "Login successful" ]]; then
    echo "${LOGIN_INFO}"
    break
  fi

  if (( $(date +"%s") - $start_time >= $IDP_TIMEOUT )); then
    echo "error: Timed out while waiting for the htpasswd idp to be ready for login"
    exit 1
  fi
done

echo "Waiting for cluster-admin ready..."
start_time=$(date +"%s")
while true; do
  sleep 30
  echo "Attempt to get cluster-admins group..."
  cluster_admin=$(oc get group cluster-admins -o json | jq -r '.users[0]' || true)
  if [[ "${cluster_admin}" == "${IDP_USER}" ]]; then
    echo "cluster-admin is granted succesffully on the user ${cluster_admin}"
    break
  fi

  if (( $(date +"%s") - $start_time >= $IDP_TIMEOUT )); then
    echo "error: Timed out while waiting for cluster-admin to be granted"
    exit 1
  fi
done

# Store kubeconfig
echo "Kubeconfig file: ${KUBECONFIG}"
cat ${KUBECONFIG} > "${SHARED_DIR}/kubeconfig"
