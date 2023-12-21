#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

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
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# The API_URL is not registered ASAP, we need to wait for a while.
API_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.api.url')
# if [[ "${API_URL}" == "null" ]]; then
#   port="6443"
#   if [[ "$HOSTED_CP" == "true" ]]; then
#     port="443"
#   fi
#   echo "warning: API URL was null, attempting to build API URL"
#   base_domain=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.dns.base_domain')
#   CLUSTER_NAME=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.name')
#   echo "info: Using baseDomain : ${base_domain} and clusterName : ${CLUSTER_NAME}"
#   API_URL="https://api.${CLUSTER_NAME}.${base_domain}:${port}"
# fi

# Config htpasswd idp
# The expected time for the htpasswd idp configuaration is in 1 minute. But actually, we met the waiting time
# is over 10 minutes, so we give a loop to wait for the configuration to be active before timeout.
echo "Config htpasswd idp ..."
IDP_USER="rosa-admin"
IDP_PASSWD="HTPasswd_$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)"
rosa create idp -c ${CLUSTER_ID} \
                -y \
                --type htpasswd \
                --name rosa-htpasswd \
                --username ${IDP_USER} \
                --password ${IDP_PASSWD}
echo "oc login ${API_URL} -u ${IDP_USER} -p ${IDP_PASSWD} --insecure-skip-tls-verify=true" > "${SHARED_DIR}/api.login"

# Grant cluster-admin access to the cluster
rosa grant user cluster-admin --user=${IDP_USER} --cluster=${CLUSTER_ID}

echo "Waiting for idp ready..."
set_proxy
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
