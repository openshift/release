#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

install_oc_if_needed() {
    if ! command -v oc &> /dev/null; then
        echo "oc command not found. Installing OpenShift CLI..."

        TEMP_DIR=$(mktemp -d)
        cd "$TEMP_DIR"

        LATEST_VERSION=$(curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/release.txt | grep 'Name:' | awk '{print $2}')

        OC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$LATEST_VERSION/openshift-client-linux.tar.gz"
        curl -sL "$OC_URL" -o oc.tar.gz
        tar -xzf oc.tar.gz

        USER_BIN="$HOME/bin"
        mkdir -p "$USER_BIN"

        mv oc "$USER_BIN/"

        export PATH="$USER_BIN:$PATH"

        cd -
        rm -rf "$TEMP_DIR"

        echo "oc $LATEST_VERSION installed successfully to $USER_BIN"
    else
        echo "oc is already installed: $(oc version --client | head -n1)"
    fi
}

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
  echo "Logging into ${OCM_LOGIN_ENV} with with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

# The API_URL is not registered ASAP, we need to wait for a while. 
API_URL=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" | jq -r ".api.url")
start_time=$(date +"%s")
while true; do
  if [[ "${API_URL}" != "null" ]]; then
    echo "API URL: ${API_URL}"
    break
  fi
  echo "API URL is not registered back. Wait for 60 seconds..."
  sleep 60
  API_URL=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" | jq -r ".api.url")

  if (( $(date +"%s") - $start_time >= $IDP_TIMEOUT )); then
    echo "error: Timed out while waiting for the API URL to be ready"
    exit 1
  fi
done

install_oc_if_needed

# Config htpasswd idp
# The expected time for the htpasswd idp configuaration is in 1 minute. But actually, we met the waiting time
# is over 10 minutes, so we give a loop to wait for the configuration to be active before timeout. 
echo "Config htpasswd idp ..."
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
echo "oc login ${API_URL} -u ${IDP_USER} -p ${IDP_PASSWD} --insecure-skip-tls-verify=true" > "${SHARED_DIR}/api.login"

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
