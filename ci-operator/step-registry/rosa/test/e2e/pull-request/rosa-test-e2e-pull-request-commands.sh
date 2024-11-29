#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}"
}

TEST_LABEL_FILTERS=${TEST_LABEL_FILTERS:-}

# Configure aws
REGION=${REGION:-${LEASED_RESOURCE}}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
export AWS_DEFAULT_REGION="${REGION}"

# Log in
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
rosa login --env "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

# Variables
COMMIT_FOCUS="/rosa/tests/ci/data/commit-focus"
FOCUS=$(cat "${COMMIT_FOCUS}")
FOCUS_LABEL_FILTER=""
FOCUS_SWITCH="--ginkgo.focus '${FOCUS}'"
if [[ -z "$FOCUS" ]]; then
  echo "Warning: No TC updated, focus on Critial"
  FOCUS_LABEL_FILTER="Critical"
  FOCUS_SWITCH=""
fi

LABEL_FILTER_SWITCH=""
if [[ ! -z "$FOCUS_LABEL_FILTER" ]]; then
  if [[ -z "$TEST_LABEL_FILTERS" ]]; then
    TEST_LABEL_FILTERS=${FOCUS_LABEL_FILTER}
  else
    TEST_LABEL_FILTERS="${TEST_LABEL_FILTERS}&&$FOCUS_LABEL_FILTER"
  fi
fi
if [[ ! -z "$TEST_LABEL_FILTERS" ]]; then
  echo "Label Filter: $TEST_LABEL_FILTERS"
  LABEL_FILTER_SWITCH="--ginkgo.label-filter '${TEST_LABEL_FILTERS}'"
fi

log "INFO: Start pull reqeust testing ..."
junit_xml="${ARTIFACT_DIR}/pull-request.xml"
cmd="rosatest --ginkgo.v --ginkgo.no-color --ginkgo.junit-report $junit_xml ${FOCUS_SWITCH} ${LABEL_FILTER_SWITCH}"
echo "Command: $cmd"
eval "${cmd}" 
