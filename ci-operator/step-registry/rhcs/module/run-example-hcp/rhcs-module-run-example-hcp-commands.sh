#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

RHCS_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [ -z "${RHCS_TOKEN}" ]; then
    error_exit "missing mandatory variable \$RHCS_TOKEN"
fi
export RHCS_TOKEN

RHCS_URL=https://api.stage.openshift.com
export RHCS_URL

AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [ ! -f ${AWS_SHARED_CREDENTIALS_FILE} ];then
    error_exit "missing mandatory aws credential file ${AWS_SHARED_CREDENTIALS_FILE}"
fi
export AWS_SHARED_CREDENTIALS_FILE

export AWS_REGION="${AWS_REGION:-us-west-2}"

random_md5sum=$(echo "$RANDOM" | md5sum)
random_string=$(printf '%s' ${random_md5sum} | cut -c 1-4)
export TF_VAR_cluster_name="${TF_VAR_cluster_name:-tf-ci-${random_string}}"

make run-example EXAMPLE_NAME="${EXAMPLE_NAME}"
