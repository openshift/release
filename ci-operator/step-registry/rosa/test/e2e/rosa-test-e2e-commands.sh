#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export TEST_PROFILE=${TEST_PROFILE:-}
TEST_LABEL_FILTERS=${TEST_LABEL_FILTERS:-}
TEST_TIMEOUT=${TEST_TIMEOUT:-"4h"}

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
echo "Working on the cluster: $CLUSTER_ID"
export CLUSTER_ID # maybe we should get cluster_id by TEST_PROFILE

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

# Configure aws
if [[ -z "$REGION" ]]; then
  REGION=${LEASED_RESOURCE}
fi

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION}"
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

# Variables
if [[ -z "$TEST_PROFILE" ]]; then
  log "ERROR: " "TEST_PROFILE is mandatory."
  exit 1
fi

LABEL_FILTER_SWITCH=""
if [[ ! -z "$TEST_LABEL_FILTERS" ]]; then
  LABEL_FILTER_SWITCH="--ginkgo.label-filter ${TEST_LABEL_FILTERS}"
fi

log "INFO: Start e2e testing ..."
junit_xml="${TEST_PROFILE}-$(date +%m%d%s).xml"
rosatest --ginkgo.v --ginkgo.no-color \
  --ginkgo.timeout ${TEST_TIMEOUT} \
  --ginkgo.junit-report "${ARTIFACT_DIR}/$junit_xml" \
  ${LABEL_FILTER_SWITCH}

# echo "$junit_xml" > "${SHARED_DIR}/junit-report-list"

# log "INFO: Generate report portal report ..."
# rosatest --ginkgo.v --ginkgo.no-color --ginkgo.timeout "10m" --ginkgo.label-filter "e2e-report"
