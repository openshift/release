#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
CONFIG="${SHARED_DIR}/install-config.yaml"
VPC_TAGS="${SHARED_DIR}/vpc-tags"
REGION="$(yq-go r "${CONFIG}" 'platform.aws.region')"

if [ -f "${AWSCRED}" ]; then
    echo "=> configuring aws"
    export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
    export AWS_DEFAULT_REGION="${REGION}"
else
    echo "Did not find compatible cloud provider cluster_profile"; exit 1
fi

if [ -f "${VPC_TAGS}" ]; then
    VPC_ID=$(cat "${VPC_TAGS}" | cut -d '|' -f1)
    TAGS=$(cat "${VPC_TAGS}" | cut -d '|' -f2)
    echo "=> deleting \"${TAGS}\" tags from vpc: ${VPC_ID}"
    aws ec2 delete-tags --resources "${VPC_ID}" --tags "${TAGS}"
fi
