#!/bin/bash

# ipi-aws-pre-proxy workflow creates the VPC which doesn't have the 'kubernetes.io/cluster' tag required by ALBO.
# Although the proper tagging is made on the subnets by the openshift installer.
# This script fills the VPC tagging gap by retrieving the right infrastructure ID from the cluster's subnet and adding it to the VPC.

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

AWS_SUBNET="$(yq-go r "${CONFIG}" 'platform.aws.subnets[0]')"
echo "=> Using aws subnet: ${AWS_SUBNET}"
VPC_ID="$(aws ec2 describe-subnets --subnet-ids "${AWS_SUBNET}" | jq -r '.[][0].VpcId')"
echo "=> Using vpc id: ${VPC_ID}"
INFRA_ID=$(aws ec2 describe-subnets --subnet-ids "${AWS_SUBNET}" | jq -r '.[][0].Tags[].Key' | grep 'kubernetes.io/cluster' | cut -d/ -f3)
echo "=> Using infra id: ${INFRA_ID}"

aws ec2 create-tags --resources "${VPC_ID}" --tags "Key=kubernetes.io/cluster/${INFRA_ID},Value=shared"

echo "${VPC_ID}|Key=kubernetes.io/cluster/${INFRA_ID},Value=shared" > "${VPC_TAGS}"
