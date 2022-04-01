#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

echo "Deleting AWS VPC"
if [ ! -f "${SHARED_DIR}/vpcstackname" ]; then
    echo "File ${SHARED_DIR}/vpcstackname does not exist."
    exit 1
fi

stack_name="$(cat ${SHARED_DIR}/vpcstackname)"
aws --region $REGION cloudformation delete-stack --stack-name "${stack_name}" &
wait "$!"
echo "Deleted stack"

aws --region $REGION cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
wait "$!"
echo "Waited for stack"

