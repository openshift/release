#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

source ./tests/prow_ci.sh

if [[ ! -z $ROSACLI_BUILD ]]; then
  override_rosacli_build
fi

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


# Variables
if [[ -z "$TEST_PROFILE" ]]; then
  log "ERROR: TEST_PROFILE is mandatory."
  exit 1
fi

# Envelope Junit files
JUNIT_XML=""
JUNIT_TEMP_DIR=""
run_time=""
generate_junit $USAGE $TEST_PROFILE $run_time


# Generate the label filter according ENV
if [[ ! -z $TEST_LABEL_FILTERS ]];then
  echo "[CI] Got LABEL_FILTER $TEST_LABEL_FILTERS "
fi

LABEL_FILTER_SWITCH=""
IMPORTANCE=""
generate_label_filter_switch "$TEST_LABEL_FILTERS" "$IMPORTANCE"

# Echo more info for debugging
echo "[CI] the generated LABEL_FILTER_SWITCH is $LABEL_FILTER_SWITCH"
echo "[CI] the generated JUNIT_XML is $JUNIT_XML"
echo "[CI] the generated JUNIT_TEMP_DIR is $JUNIT_TEMP_DIR" 

# Generate running cmd
FOCUS=""
cmd=$(generate_running_cmd "$LABEL_FILTER_SWITCH"  "$FOCUS" "$TEST_TIMEOUT" "$JUNIT_XML")
log "INFO: Start e2e testing ...\n$cmd"

# Execute the running cmd 
eval "${cmd}" || true

# cp ${SHARED_DIR}/junit.tar.gz ${ARTIFACT_DIR}
upload_junit_result $JUNIT_XML $SHARED_DIR ${ARTIFACT_DIR}

log "Testing is finished and uploaded."
