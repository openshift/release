#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
export TEST_PROFILE=${TEST_PROFILE:-}
TEST_LABEL_FILTERS=${TEST_LABEL_FILTERS:-}
TEST_TIMEOUT=${TEST_TIMEOUT:-"4h"}

if [[ "$TEST_PROFILE" != "null" ]]; then
  CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
  echo "Working on the cluster: $CLUSTER_ID"
  export CLUSTER_ID # this is already enhanced in rosa repo. And will remove this in another PR
fi

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}"
}

source ./tests/prow_ci.sh

if [[ ! -z $ROSACLI_BUILD ]]; then
  override_rosacli_build
fi

# rosa version # comment it now in case anybody using old version which will trigger panic issue

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
  log "ERROR: TEST_PROFILE is mandatory."
  exit 1
fi



# Envelope Junit files
junitTempDir=$(mktemp -d)

if [[ -f "${SHARED_DIR}/junit.tar.gz" ]]; then
    tar -xvf "${SHARED_DIR}/junit.tar.gz" -C $junitTempDir
fi



# Generate the label filter according ENV
LABEL_FILTER_SWITCH=""

if [[ ! -z "$TEST_LABEL_FILTERS" ]]; then
  # TEST_LABEL_FILTERS is the most high level filter. If it is set, other label filter ENVs will be ignored
  LABEL_FILTER_SWITCH="--ginkgo.label-filter '${TEST_LABEL_FILTERS}'" 
fi


# Generate junit file name
junit_xml="${junitTempDir}/rosa-e2e-${TEST_PROFILE}.xml"

# Generate running cmd
cmd="rosatest --ginkgo.v --ginkgo.no-color \
  --ginkgo.timeout ${TEST_TIMEOUT} \
  --ginkgo.junit-report $junit_xml \
  ${LABEL_FILTER_SWITCH}"
log "INFO: Start e2e testing ...\n$cmd"

# Execute the running cmd 
eval "${cmd}" || true

# Remove old junit file
rm -rf ${SHARED_DIR}/junit.tar.gz

# tar and upload the junit results
cd $junitTempDir
tar -zcvf ${SHARED_DIR}/junit.tar.gz *.xml

# Archive the results
cp ${SHARED_DIR}/junit.tar.gz ${ARTIFACT_DIR}
log "Testing is finished and uploaded."
