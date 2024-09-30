#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export REGION=${REGION:-}
export TEST_PROFILE=${TEST_PROFILE}
export VERSION=${VERSION:-}
export WAIT_SETUP_CLUSTER_READY=${WAIT_SETUP_CLUSTER_READY:-false}

CLUSTER_SECTOR=${CLUSTER_SECTOR:-}

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}"
}

source ./tests/prow_ci.sh

if [[ ! -z $ROSACLI_BUILD ]]; then
  override_rosacli_build
fi

# functions are defined in https://github.com/openshift/rosa/blob/master/tests/prow_ci.sh
#configure aws
aws_region=${REGION:-$LEASED_RESOURCE}
configure_aws "${CLUSTER_PROFILE_DIR}/.awscred" "${aws_region}"
configure_aws_shared_vpc ${CLUSTER_PROFILE_DIR}/.awscred_shared_account

# Log in to rosa/ocm
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
rosa_login ${OCM_LOGIN_ENV} $OCM_TOKEN

AWS_ACCOUNT_ID=$(rosa whoami --output json | jq -r '."AWS Account ID"')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

# Variables
if [[ -z "$TEST_PROFILE" ]]; then
  log "ERROR: " "TEST_PROFILE is mandatory."
  exit 1
fi

# get shard id based on sector
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
  --ginkgo.timeout "60m" \
  --ginkgo.label-filter "day1" | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"
