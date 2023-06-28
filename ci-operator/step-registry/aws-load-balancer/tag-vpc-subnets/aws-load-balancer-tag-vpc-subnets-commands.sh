#!/bin/bash

# ipi-aws-pre-proxy workflow doesn't tag the following AWS resources the way ALBO requires:
#   - VPC doesn't have the 'kubernetes.io/cluster' tag
#   - subnets don't have the ELB role tags
# This script aims at filling these tagging gaps, for more info about ALBO prerequisites, see
# https://github.com/openshift/aws-load-balancer-operator/blob/main/docs/prerequisites.md#vpc-and-subnets.

set -o nounset
set -o errexit
set -o pipefail

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
CONFIG="${SHARED_DIR}/install-config.yaml"
REGION="$(yq-go r "${CONFIG}" 'platform.aws.region')"

if [ -f "${AWSCRED}" ]; then
    echo "=> configuring aws"
    export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
    export AWS_DEFAULT_REGION="${REGION}"
else
    echo "Did not find compatible cloud provider cluster_profile"; exit 1
fi

SUBNET0="$(yq-go r "${CONFIG}" 'platform.aws.subnets[0]')"
VPC_ID="$(aws ec2 describe-subnets --subnet-ids "${SUBNET0}" | jq -r '.[][0].VpcId')"
INFRA_ID=$(aws ec2 describe-subnets --subnet-ids "${SUBNET0}" | jq -r '.[][0].Tags[].Key' | grep 'kubernetes.io/cluster' | cut -d/ -f3)

echo "=> tagging vpc ${VPC_ID} with ${INFRA_ID} cluster tag"
aws ec2 create-tags --resources "${VPC_ID}" --tags "Key=kubernetes.io/cluster/${INFRA_ID},Value=shared"

for SUBNET in $(yq-go r "${CONFIG}" 'platform.aws.subnets[*]'); do
    if grep -q PrivateSubnet <(aws ec2 describe-subnets --subnet-ids "${SUBNET}" | jq -r '.[][0].Tags[].Value'); then
        # ALBO cannot distinguish private and public subnets yet,
        # so it treats all the untagged subnets as public, see
        # https://github.com/openshift/aws-load-balancer-operator/blob/7f0d1d22fe03fbf2fc2b5c1f11c3e6a1818421ce/pkg/controllers/awsloadbalancercontroller/subnettagging.go#L70-L71.
        # The code below puts the internal ELB tag on the private subnets
        # letting ALBO tag the rest with the public ELB tag.
        echo "=> tagging private subnet ${SUBNET} with internal elb role"
        aws ec2 create-tags --resources "${SUBNET}" --tags "Key=kubernetes.io/role/internal-elb,Value=1"
    fi
done
