#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

ls ${SHARED_DIR}

cp -r /root/terraform-provider-rhcs ~/

# Copy the manifest folder to the shared DIR for below steps share
##cp -r  ~/terraform-provider-rhcs/tests/tf-manifests ${SHARED_DIR}/tf-manifests
##cd ${SHARED_DIR}
##tar -xvf statefiles.tar.gz

##ls -R ${SHARED_DIR}/tf-manifests

cd  ~/terraform-provider-rhcs
export CLUSTER_PROFILE=${CLUSTER_PROFILE}
export QE_USAGE=${QE_USAGE}
export WAIT_OPERATORS=${WAIT_OPERATORS}
export CHANNEL_GROUP=${CHANNEL_GROUP}
export RHCS_URL=${RHCS_URL}
export VERSION=${VERSION}
export REGION=${REGION}

export GOCACHE="/tmp/cache"
export GOMODCACHE="/tmp/cache"
export GOPROXY=https://proxy.golang.org
go mod download
go mod tidy
go mod vendor

RHCS_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [ -z "${RHCS_TOKEN}" ]; then
    error_exit "missing mandatory variable \$RHCS_TOKEN"
fi
export RHCS_TOKEN=${RHCS_TOKEN}
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred


if [ ! -f ${CLUSTER_PROFILE_DIR}/.awscred ];then
    error_exit "missing mandatory aws credential file ${CLUSTER_PROFILE_DIR}/.awscred"
fi

REGION=${REGION:-$LEASED_RESOURCE}
export AWS_DEFAULT_REGION="${REGION}"

#export MANIFESTS_FOLDER=${SHARED_DIR}/tf-manifests
#if [ ! -d $MANIFESTS_FOLDER ];then
#    error_exit "There is no $MANIFESTS_FOLDER existing for tests running. Please make sure your setup run successfully and the manifests dir copied successfully"
#fi
export RHCS_OUTPUT=${SHARED_DIR} # this is the sensitive information sharing folder between steps

if [ ! -z "$RHCS_SOURCE" ];then
    export RHCS_SOURCS=$RHCS_SOURCE
fi
if [ ! -z "$RHCS_VERSION" ]; then
    export RHCS_VERSION=$RHCS_VERSION
fi

# Define the junit name
junitFileName="result-junit.xml"

make tools
make install
echo ">>> ENV prepare successfully, start to run the tests now. "
label_filter='(Critical,High)&&(day1-post,day2)&&!Exclude'
if [ ! -z "$CASE_LABEL_FILTER" ]; then
    label_filter="$CASE_LABEL_FILTER"
fi

echo ">>> CI run label filter is: $label_filter. Cases match label will be filtered."

# Below step will skip gcc checking
export CGO_ENABLED=0

# The exit status of ginkgo is the source of truth for pass/fail. pipefail is set, so the
# pipe to tee preserves it. Hold it until the end so the junit upload below still runs.
test_exit=0
ginkgo run \
    --label-filter $label_filter \
    --timeout 2h \
    --output-dir ${SHARED_DIR} \
    --junit-report $junitFileName \
    -r \
    --focus-file tests/e2e/.* | tee ${SHARED_DIR}/rhcs_tests.log || test_exit=$?

cd ~/terraform-provider-rhcs

# copy testing result to ARTIFACT_DIR to expose
if [ -f ${SHARED_DIR}/$junitFileName ]; then
    cp ${SHARED_DIR}/$junitFileName ${ARTIFACT_DIR}
else
    echo ">>> WARN: no junit at ${SHARED_DIR}/$junitFileName. The tests likely died before writing results."
fi

# Introduce force success exit
if [ "W${FORCE_SUCCESS_EXIT}W" == "WyesW" ]; then
    echo "force success exit"
    test_exit=0
fi

exit ${test_exit}
