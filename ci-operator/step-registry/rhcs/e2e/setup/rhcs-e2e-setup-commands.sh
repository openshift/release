#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

save_state_files() {
    # tar the shared manifest dir to make it share between pods
    cd ${SHARED_DIR}
    find ./tf-manifests -name 'terraform.[tfstate|tfvars]*' -print0|tar --null -T - -zcvf statefiles.tar.gz
    ls ${SHARED_DIR}
    cd -
}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi; save_state_files' TERM


export GOCACHE="/tmp/cache"
export GOMODCACHE="/tmp/cache"
export GOPROXY=https://proxy.golang.org


cp -r /root/terraform-provider-rhcs ~/
cd ~/terraform-provider-rhcs

go mod download
go mod tidy
go mod vendor

if [ -d ${SHARED_DIR}/tf-manifests ]; then
    rm -rf ${SHARED_DIR}/tf-manifests
fi

# Copy the manifest folder to the shared DIR for below steps share
cp -r  ~/terraform-provider-rhcs/tests/tf-manifests ${SHARED_DIR}/tf-manifests


RHCS_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [ -z "${RHCS_TOKEN}" ]; then
    error_exit "missing mandatory variable \$RHCS_TOKEN"
fi
export RHCS_TOKEN=${RHCS_TOKEN}
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred

if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
    export SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred_shared_account
fi

if [ ! -f ${CLUSTER_PROFILE_DIR}/.awscred ];then
    error_exit "missing mandatory aws credential file ${CLUSTER_PROFILE_DIR}/.awscred"
fi

REGION=${REGION:-$LEASED_RESOURCE}
export AWS_DEFAULT_REGION="${REGION}"

if [ -z "$AWS_DEFAULT_REGION" ];then
    export AWS_DEFAULT_REGION="us-east-2"
fi

# export the manifests dir
export MANIFESTS_FOLDER=${SHARED_DIR}/tf-manifests
export RHCS_OUTPUT=${SHARED_DIR}

# Export the manifests folder to the shared dir
export CLUSTER_PROFILE=${CLUSTER_PROFILE}
export QE_USAGE=${QE_USAGE}
export WAIT_OPERATORS=${WAIT_OPERATORS}
export CHANNEL_GROUP=${CHANNEL_GROUP}
export RHCS_ENV=${RHCS_ENV}
export RHCS_URL=${RHCS_URL}
export RHCS_TOKEN=${RHCS_TOKEN}
export VERSION=${VERSION}
export REGION=${REGION}
if [ ! -z "$RHCS_SOURCE" ];then
    export RHCS_SOURCS=$RHCS_SOURCE
fi
if [ ! -z "$RHCS_VERSION" ]; then
    export RHCS_VERSION=$RHCS_VERSION
fi

make tools
make install

# Below step will skip gcc checking
export CGO_ENABLED=0

ginkgo run \
    --label-filter day1-prepare \
    --timeout 2h \
    -r \
    --focus-file tests/e2e/.* 2>&1| tee ${SHARED_DIR}/rhcs_preparation.log || true

save_state_files

prepareFailure=$(tail -n 100 ${SHARED_DIR}/rhcs_preparation.log | { grep "\[FAIL\]" || true; })

# clean files before leaving
rm -rf ${SHARED_DIR}/tf-manifests
rm -rf ${SHARED_DIR}/rhcs_preparation.log

if [ ! -z "$prepareFailure" ]; then
    exit 1
fi
