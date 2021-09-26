#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
CONFIG="${SHARED_DIR}/install-config.yaml"

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

REGION="${LEASED_RESOURCE}"

CLUSTER_NAME="$(/tmp/yq r "${CONFIG}" 'metadata.name')"

curl -L https://raw.githubusercontent.com/openshift/installer/master/upi/aws/cloudformation/01_vpc.yaml -o /tmp/01_vpc.yaml

# The above cloudformation template's max zones account is 3
if [[ "${ZONES_COUNT}" -gt 3 ]]
then
  ZONES_COUNT=3
fi

STACK_NAME="${CLUSTER_NAME}-vpc"
aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat /tmp/01_vpc.yaml)" \
  --tags "${TAGS}" \
  --parameters "ParameterKey=AvailabilityZoneCount,ParameterValue=${ZONES_COUNT}" &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Waited for stack"

# save stack information to ${SHARED_DIR} for deprovision step
echo "${STACK_NAME}" > "${SHARED_DIR}/vpcstackname"

# save vpc stack output
aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > "${SHARED_DIR}/vpcoutput"

# save vpc id
# e.g. 
#   vpc-01739b6510a152d44
VpcId=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="VpcId") | .OutputValue' "${SHARED_DIR}/vpcoutput")
echo "$VpcId" > "${SHARED_DIR}/vpcid"
echo "VpcId: ${VpcId}"

# all subnets
# ['subnet-pub1', 'subnet-pub2', 'subnet-priv1', 'subnet-priv2']
AllSubnetsIds="$(jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]' "${SHARED_DIR}/vpcoutput" | sed "s/\"/'/g")"
echo "$AllSubnetsIds" > "${SHARED_DIR}/allsubnetids"

# save public subnets ids
# ['subnet-pub1', 'subnet-pub2']
PublicSubnetIds="$(jq -c '[.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue | split(",")[]]' "${SHARED_DIR}/vpcoutput" | sed "s/\"/'/g")"
echo "$PublicSubnetIds" > "${SHARED_DIR}/publicsubnetids"
echo "PublicSubnetIds: ${PublicSubnetIds}"

# save private subnets ids
# ['subnet-priv1', 'subnet-priv2']
PrivateSubnetIds="$(jq -c '[.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue | split(",")[]]' "${SHARED_DIR}/vpcoutput" | sed "s/\"/'/g")"
echo "$PrivateSubnetIds" > "${SHARED_DIR}/privatesubnetids"
echo "PrivateSubnetIds: ${PrivateSubnetIds}"


# output: ['subnet-045024152d76c74fc','subnet-0107825ef27dfefa4','subnet-08b8f4f03e7f5172f','subnet-010adebbf0bf628c9','subnet-03b660891d311091f','subnet-08242f9ab76d449ef']
# subnets="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]' | sed "s/\"/'/g")"
# echo "Subnets : ${subnets}"

cp "${SHARED_DIR}/vpcstackname" "${ARTIFACT_DIR}/"
cp "${SHARED_DIR}/vpcid" "${ARTIFACT_DIR}/"
cp "${SHARED_DIR}/allsubnetids" "${ARTIFACT_DIR}/"
cp "${SHARED_DIR}/publicsubnetids" "${ARTIFACT_DIR}/"
cp "${SHARED_DIR}/privatesubnetids" "${ARTIFACT_DIR}/"
