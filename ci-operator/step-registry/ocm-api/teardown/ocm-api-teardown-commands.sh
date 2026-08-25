#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function logger() {
  local -r log_level=$1; shift
  local -r log_msg=$1; shift
  echo "$(date -u --rfc-3339=seconds) - ${log_level}: ${log_msg}"
}


trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export TEST_PROFILE=${TEST_PROFILE:-}
export VERSION=${VERSION:-}
export CHANNEL_GROUP=${CHANNEL_GROUP:-}

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
logger "INFO" "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"


ocmTempDir=$(mktemp -d)
cd $ocmTempDir
wget https://gitlab.cee.redhat.com/service/ocm-backend-tests/-/archive/master/ocm-backend-tests-master.tar.gz --no-check-certificate
tar -zxf ocm-backend-tests-master.tar.gz
mv ocm-backend-tests-master ocm-backend-tests
cd ocm-backend-tests/
make cmds
chmod +x ./testcmd/*
cp ./testcmd/* $ocmTempDir/
export PATH=$ocmTempDir:$PATH

export ORG_MEMBER_TOKEN=$OCM_TOKEN
export CLUSTER_PROFILE=$TEST_PROFILE
export CLUSTER_PROFILE_DIR=$SHARED_DIR
export OCM_ENV=$OCM_LOGIN_ENV
export OCPE2E_TEST=true
export DEBUG=false

cms --ginkgo.v --ginkgo.no-color --ginkgo.timeout 1h --ginkgo.focus CleanClusterByProfile --ginkgo.label-filter feature-cleaner

