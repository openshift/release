#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

echo "Deleting AWS bastion host"
if [ ! -f "${SHARED_DIR}/bastionhoststackname" ]; then
    echo "File ${SHARED_DIR}/bastionhoststackname does not exist."
    exit 1
fi

stack_name="$(cat ${SHARED_DIR}/bastionhoststackname)"
aws --region $REGION cloudformation delete-stack --stack-name "${stack_name}" &
wait "$!"
echo "Deleted stack"

aws --region $REGION cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
wait "$!"
echo "Waited for stack"

echo "Deleting s3 bucket of bastion host"
if [ ! -f "${SHARED_DIR}/bastionhosts3bucket" ]; then
    echo "File ${SHARED_DIR}/bastionhosts3bucket does not exist."
    exit 1
fi

s3_bucket="$(cat ${SHARED_DIR}/bastionhosts3bucket)"
aws --region $REGION s3 rb ${s3_bucket} --force &
wait "$!"
echo "Deleted s3 bucket"
