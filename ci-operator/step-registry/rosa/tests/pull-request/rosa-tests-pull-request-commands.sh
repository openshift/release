#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

source ./tests/prow_ci.sh

TEST_TIMEOUT=${TEST_TIMEOUT:-"4h"}

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}"
}

# functions are defined in https://github.com/openshift/rosa/blob/master/tests/prow_ci.sh
#configure aws
aws_region=${REGION:-$LEASED_RESOURCE}
configure_aws "${CLUSTER_PROFILE_DIR}/.awscred" "${aws_region}"
configure_aws_shared_vpc ${CLUSTER_PROFILE_DIR}/.awscred_shared_account

# Log in to rosa/ocm
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
rosa_login ${OCM_LOGIN_ENV} $OCM_TOKEN

# Get the focus IDs from the tests
COMMIT_FOCUS="/rosa/tests/ci/data/commit-focus"
FOCUS=$(cat "${COMMIT_FOCUS}")

IMPORTANCE=""
if [[ -z $FOCUS ]]; then
  IMPORTANCE="Critical" # when focus cases are empty, will run critical cases only
fi

# Variables
if [[ -z "$TEST_PROFILE" ]]; then
  log "ERROR: TEST_PROFILE is mandatory."
  exit 1
fi

# Envelope Junit files
JUNIT_XML=""
JUNIT_TEMP_DIR=""

run_testing_steps () {
  RUN_TIME="$1" #running based on the passed runtime
  message="[CI] Running runtime $RUN_TIME cases"
  if [[ ! -z $IMPORTANCE ]];then
    message="$message with importance: $IMPORTANCE"
  fi
  if [[ ! -z "$FOCUS" ]];then
    message="$message with focused cases: $FOCUS"
  fi
  log "[CI] $message"
  generate_junit "pr" "$TEST_PROFILE" "$RUN_TIME"
  # Generate the label filter according ENV

  LABEL_FILTER="${RUN_TIME}&&!Exclude"
  LABEL_FILTER_SWITCH="" # LABEL_FILTER_SWITCH is generated based on LABEL_FILTER and IMPORTANCE
  generate_label_filter_switch "$LABEL_FILTER" "$IMPORTANCE"

  # echo more info to debug
  log "[CI] the generated LABEL_FILTER_SWITCH is $LABEL_FILTER_SWITCH"
  log "[CI] the generated JUNIT_XML is $JUNIT_XML"
  log "[CI] the generated JUNIT_TEMP_DIR is $JUNIT_TEMP_DIR" 
  
  # Generate running cmd for $RUN_TIME
  if [[ "${RUN_TIME}" == "destroy" ]]; then
    cmd=$(generate_running_cmd "$LABEL_FILTER_SWITCH" "" "$TEST_TIMEOUT" "$JUNIT_XML")
  else
    cmd=$(generate_running_cmd "$LABEL_FILTER_SWITCH" "$FOCUS" "$TEST_TIMEOUT" "$JUNIT_XML")
  fi
  log "[CI] Start e2e testing with command $cmd\n"

  # Execute the day1-post running cmd combined with focus
  eval "${cmd}" || true

  upload_junit_result $JUNIT_XML $SHARED_DIR ${ARTIFACT_DIR}
  log "[CI] Testing is finished and uploaded."
}

declare -a run_times=(
  "day1-post"
  "day2"
  "destructive"
  "destroy" 
  "destroy-post"
)
for run_time in "${run_times[@]}"; do
  run_testing_steps $run_time
done
