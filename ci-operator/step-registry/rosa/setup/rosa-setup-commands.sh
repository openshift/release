#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export REGION=${REGION:-}
export TEST_PROFILE=${TEST_PROFILE}
export COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"m5.xlarge"}
export OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
export CHANNEL_GROUP=${CHANNEL_GROUP:-"stable"}
export WAIT_SETUP_CLUSTER_READY=${WAIT_SETUP_CLUSTER_READY:-false}
CLUSTER_SECTOR=${CLUSTER_SECTOR:-}

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}"
}

source ./tests/prow_ci.sh

if [[ ! -z $ROSACLI_BUILD ]]; then
  override_rosacli_build
fi

# Configure aws
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION=${REGION:-$LEASED_RESOURCE}
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV}"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to specify the offline token OCM_TOKEN!"
  exit 1
fi
AWS_ACCOUNT_ID=$(rosa whoami --output json | jq -r '."AWS Account ID"')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

# Variables
if [[ -z "$TEST_PROFILE" ]]; then
  log "ERROR: " "TEST_PROFILE is mandatory."
  exit 1
fi

if [[ ! -z "${CLUSTER_SECTOR}" ]]; then
  psList=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${CLOUD_PROVIDER_REGION}' and status in ('ready')" | jq -r '.items[].provision_shard_reference.id')
  if [[ -z "$psList" ]]; then
    echo "no ready provision shard found, trying to find maintenance status provision shard"
    # try to find maintenance mode SC, currently osdfm api doesn't support status in ('ready', 'maintenance') query.
    psList=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${CLOUD_PROVIDER_REGION}' and status in ('maintenance')" | jq -r '.items[].provision_shard_reference.id')
    if [[ -z "$psList" ]]; then
      echo "No available provision shard!"
      exit 1
    fi
  fi
  psID=$(echo "$psList" | head -n 1)
  export PROVISION_SHARD_ID=$psID
fi

rosatest --ginkgo.v --ginkgo.no-color \
  --ginkgo.timeout "30m" \
  --ginkgo.label-filter "day1" | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"
# CLUSER_ID=$(cat "${SHARED_DIR}/cluster-id")
# CLUSER_NAME=$(rosa describe cluster -c ${CLUSER_ID} -o json | jq -r '.name')
# echo "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"
