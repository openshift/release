#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Record Cluster Configurations
cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

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
set_proxy

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


# For hcp cluster with external auth, it is not supportted to create htpasswd idp. 
# So we can create a temp break glass credential to login cluster 

HOSTED_CP=${HOSTED_CP:-false}
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
EXTERNAL_AUTH=$(rosa describe cluster -c "${CLUSTER_ID}" -o json  | jq -r '.external_auth_config.enabled')
HOSTED_CP=$(rosa describe cluster -c "${CLUSTER_ID}" -o json  | jq -r '.hypershift.enabled')

if [[ "$HOSTED_CP" == "true" ]] && [[ "${EXTERNAL_AUTH}" == "true" ]]; then
  echo "Create break-glass-credential to HCP cluster..."
  rosa create break-glass-credential -c  "$CLUSTER_ID" 
  BREAK_CRE_ID=$(rosa list  break-glass-credential -c  "$CLUSTER_ID"  -o json | jq -r '.[0].id')
  while true; do
     sleep 30
     echo "Attempt to get break-glass-credential..."
     BREAK_CRE_STATUS=$(rosa list  break-glass-credential -c  "$CLUSTER_ID"  -o json | jq -r '.[0].status')
     if [[ "${BREAK_CRE_STATUS}" == "issued" ]]; then
        echo "Cluster break glass credential is ready"
        break
     fi
  done

  rosa describe break-glass-credential --id "$BREAK_CRE_ID"  -c  "$CLUSTER_ID"  --kubeconfig > "${SHARED_DIR}/kubeconfig"
  
  echo "Kubeconfig file: "
  cat ${SHARED_DIR}/kubeconfig
fi

