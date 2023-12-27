#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM


ls ${SHARED_DIR}

cp -r /root/terraform-provider-rhcs ~/

# Copy the manifest folder to the shared DIR for below steps share
cp -r  ~/terraform-provider-rhcs/tests/tf-manifests ${SHARED_DIR}/tf-manifests
cd ${SHARED_DIR}
tar -xvf statefiles.tar.gz

ls -R ${SHARED_DIR}/tf-manifests

cd  ~/terraform-provider-rhcs

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

export MANIFESTS_FOLDER=${SHARED_DIR}/tf-manifests
if [ ! -d $MANIFESTS_FOLDER ];then
    error_exit "There is no $MANIFESTS_FOLDER existing for tests running. Please make sure your setup run successfully and the manifests dir copied successfully"
fi
export RHCS_OUTPUT=${SHARED_DIR} # this is the sensitive information sharing folder between steps

export GATEWAY_URL=$GATEWAY_URL

export CLUSTER_PROFILE=${CLUSTER_PROFILE}
export CHANNEL_GROUP=${CHANNEL_GROUP}
export RHCS_ENV=${RHCS_ENV}
export VERSION=${VERSION}
export REGION=${REGION}

# Define the junit name
junitFileName="result.xml"

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

ginkgo run \
    --label-filter $label_filter \
    --timeout 2h \
    --output-dir ${SHARED_DIR} \
    --junit-report $junitFileName \
    -r \
    --focus-file tests/e2e/.* | tee ${SHARED_DIR}/rhcs_tests.log

# tar the shared manifest dir to make it share between pods
cd ${SHARED_DIR}
find ./tf-manifests -name 'terraform.[tfstate|tfvars]*' -print0|tar --null -T - -zcvf statefiles.tar.gz
ls ${SHARED_DIR}

cd ~/terraform-provider-rhcs

# copy testing result to ARTIFACT_DIR to expose
cp ${SHARED_DIR}/$junitFileName ${ARTIFACT_DIR}

# Introduce force success exit
if [ "W${FORCE_SUCCESS_EXIT}W" == "WyesW" ]; then
    echo "force success exit"
    exit 0
fi

testFailure=$(tail -n 100 ${SHARED_DIR}/rhcs_tests.log | { grep "\[FAIL\]" || true; })
if [ ! -z "$testFailure" ]; then
    sleep 1800 #Sleep 1800 to debug why cluster dns not ready
    exit 1
fi