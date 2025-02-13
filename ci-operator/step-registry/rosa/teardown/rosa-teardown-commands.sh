#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}"
}

source ./tests/prow_ci.sh

if [[ ! -z $ROSACLI_BUILD ]]; then
  override_rosacli_build
fi

# rosa version # comment it now in case anybody using old version which will trigger panic issue

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

# Deprovision cluster and resources
rosatest --ginkgo.v --ginkgo.no-color \
  --ginkgo.timeout "1h" \
  --ginkgo.label-filter "destroy" | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"
