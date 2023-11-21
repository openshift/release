#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
VPC_ID=$(cat "${SHARED_DIR}/vpc_id")

for sg_name in ${CLUSTER_NAME}-test-sg-1 ${CLUSTER_NAME}-test-sg-2 ${CLUSTER_NAME}-test-sg-3
do
    aws ec2 create-security-group --region $REGION --group-name ${sg_name} --vpc-id $VPC_ID --output text --description "Testing custom security group usage" >> ${SHARED_DIR}/security_groups_ids
done
