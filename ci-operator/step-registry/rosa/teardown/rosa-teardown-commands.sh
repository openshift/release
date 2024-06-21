#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export TEST_PROFILE=${TEST_PROFILE}
# export CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}"
}

source ./tests/prow_ci.sh

if [[ ! -z $ROSACLI_BUILD ]]; then
  override_rosacli_build
fi

# rosa version # comment it now in case anybody using old version which will trigger panic issue

# Configure aws
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"
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

# Deprovision cluster and resources
rosatest --ginkgo.v --ginkgo.no-color \
  --ginkgo.timeout "1h" \
  --ginkgo.label-filter "destroy" | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"
