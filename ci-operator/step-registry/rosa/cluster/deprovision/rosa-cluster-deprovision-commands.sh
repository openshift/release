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

# Log in
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
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
while rosa describe cluster -c "${CLUSTER_ID}" ; do
  current_time=$(date +"%s")
  if (( "${current_time}" - "${start_time}" >= "${DESTROY_TIMEOUT}" )); then
    echo "error: Cluster not deleted after ${DESTROY_TIMEOUT}"
    exit 1
  else
    echo "Cluster ${CLUSTER_ID} is still alive, waiting 60 seconds for the next check"
    sleep 60
  fi
done
end_time=$(date +"%s")
echo "Cluster destroyed after $(( ${end_time} - ${start_time} )) seconds"
record_cluster "timers" "destroy" $(( "${end_time}" - "${start_time}" ))

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
