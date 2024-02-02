#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

RHCS_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [ -z "${RHCS_TOKEN}" ]; then
    error_exit "missing mandatory variable \$RHCS_TOKEN"
fi
export RHCS_TOKEN

AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [ ! -f ${AWS_SHARED_CREDENTIALS_FILE} ];then
    error_exit "missing mandatory aws credential file ${AWS_SHARED_CREDENTIALS_FILE}"
fi
export AWS_SHARED_CREDENTIALS_FILE

shared_vpc_aws_cred="${CLUSTER_PROFILE_DIR}/.awscred-shared-vpc"
if [ ! -f ${shared_vpc_aws_cred} ];then
    error_exit "missing mandatory aws credential file ${shared_vpc_aws_cred}"
fi
TF_VAR_shared_vpc_aws_access_key_id=$(cat ${shared_vpc_aws_cred} | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f2)
export TF_VAR_shared_vpc_aws_access_key_id
TF_VAR_shared_vpc_aws_secret_access_key=$(cat ${shared_vpc_aws_cred} | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f2)
export TF_VAR_shared_vpc_aws_secret_access_key

export AWS_REGION="${AWS_REGION:-us-east-1}"
export TF_VAR_shared_vpc_aws_region="${TF_VAR_shared_vpc_aws_region:-us-east-1}"

random_md5sum=$(echo "$RANDOM" | md5sum)
random_string=$(printf '%s' ${random_md5sum} | cut -c 1-4)
export TF_VAR_cluster_name="${TF_VAR_cluster_name:-tf-ci-${random_string}}"

make run-example EXAMPLE_NAME="${EXAMPLE_NAME}"
