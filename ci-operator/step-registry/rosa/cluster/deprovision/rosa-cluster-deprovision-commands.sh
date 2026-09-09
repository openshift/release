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

CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}

# Configure aws
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

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id" || true)
if [[ -z "$CLUSTER_ID" ]]; then
  CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-name" || true)
  if [[ -z "$CLUSTER_ID" ]]; then
    echo "No cluster is created. Softly exit the cluster deprovision."
    exit 0
  fi
fi

echo "Deleting cluster-id: ${CLUSTER_ID}"
start_time=$(date +"%s")
rosa delete cluster -c "${CLUSTER_ID}" -y
while true; do
  CLUSTER_STATE=$(rosa describe cluster -c "${CLUSTER_ID}" -o json 2>/dev/null | jq -r '.state' || true)
  echo "Cluster state: ${CLUSTER_STATE}"
  current_time=$(date +"%s")
  if (( "${current_time}" - "${start_time}" >= "${DESTROY_TIMEOUT}" )); then
    echo "error: Cluster not deleted after ${DESTROY_TIMEOUT}"
    exit 1
  else
    if [[ "${CLUSTER_STATE}" == "error" ]]; then
      echo "Cluster ${CLUSTER_ID} is on error state and wont be deleted."
      exit 1
    elif [[ "${CLUSTER_STATE}" == "" ]]; then
      end_time=$(date +"%s")
      echo "Cluster destroyed after $(( ${end_time} - ${start_time} )) seconds"
      record_cluster "timers" "destroy" $(( "${end_time}" - "${start_time}" ))
      break
    else
      echo "Cluster ${CLUSTER_ID} is on ${CLUSTER_STATE} state, waiting 60 seconds for the next check"
      sleep 60
    fi
  fi
done

if [[ "$STS" == "true" ]]; then
  start_time=$(date +"%s")
  echo "Deleting operator roles"
  rosa delete operator-roles -c "${CLUSTER_ID}" -y -m auto

  echo "Deleting oidc-provider"
  rosa delete oidc-provider -c "${CLUSTER_ID}" -y -m auto

  end_time=$(date +"%s")
  record_cluster "timers" "sts_destroy" $(( "${end_time}" - "${start_time}" ))
  echo "STS resoures of ${CLUSTER_ID} deleted after $(( ${end_time} - ${start_time} )) seconds"
fi
echo "Do a smart 120 sleeping to make sure the processes are complted."
sleep 120

echo "Cluster is no longer accessible; delete successful."
exit 0
