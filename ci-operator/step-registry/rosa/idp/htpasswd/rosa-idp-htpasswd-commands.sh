#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

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
ROSA_VERSION=$(rosa version)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${ROSA_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# Config htpasswd idp
# The expected time for the htpasswd idp configuaration is in 1 minute. But actually, we met the waiting time
# is over 10 minutes, so we give a loop to wait for the configuration to be active before timeout. 
echo "Config htpasswd idp ..."
IDP_USER="rosa-admin"
IDP_PASSWD=$(openssl rand -base64 15)
rosa create idp -c ${CLUSTER_ID} \
                -y \
                --type htpasswd \
                --name rosa-htpasswd \
                --username ${IDP_USER} \
                --password ${IDP_PASSWD}

API_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.api.url')
echo "oc login ${API_URL} -u ${IDP_USER} -p ${IDP_PASSWD} --insecure-skip-tls-verify=true" > "${SHARED_DIR}/api.login"

# Grant cluster-admin access to the cluster
rosa grant user cluster-admin --user=${IDP_USER} --cluster=${CLUSTER_ID}

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

# Store kubeconfig
echo "Kubeconfig file: ${KUBECONFIG}"
cat ${KUBECONFIG} > "${SHARED_DIR}/kubeconfig"
