#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

function join_by { local IFS="$1"; shift; echo "$*"; }

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-sharednetwork.yaml.patch

REGION="${LEASED_RESOURCE}"

CLUSTER_NAME="$(yq-go r "${CONFIG}" 'metadata.name')"

curl -L https://raw.githubusercontent.com/openshift/installer/master/upi/aws/cloudformation/01_vpc.yaml -o /tmp/01_vpc.yaml

# The above cloudformation template's max zones account is 3
if [[ "${ZONES_COUNT}" -gt 3 ]]
then
  ZONES_COUNT=3
fi

STACK_NAME="${CLUSTER_NAME}-shared-vpc"
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

subnets="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]' | sed "s/\"/'/g")"
echo "Subnets : ${subnets}"

# save stack information to ${SHARED_DIR} for deprovision step
echo "${STACK_NAME}" >> "${SHARED_DIR}/sharednetworkstackname"

# Generate working availability zones from the region
mapfile -t AVAILABILITY_ZONES < <(aws --region "${REGION}" ec2 describe-availability-zones --filters Name=state,Values=available Name=zone-type,Values=availability-zone | jq -r '.AvailabilityZones[].ZoneName' | sort -u)
ZONES=("${AVAILABILITY_ZONES[@]:0:${ZONES_COUNT}}")
ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
echo "AWS region: ${REGION} (zones: ${ZONES_STR})"

cat > "${PATCH}" << EOF
controlPlane:
  platform:
    aws:
      zones: ${ZONES_STR}
compute:
- platform:
    aws:
      zones: ${ZONES_STR}
platform:
  aws:
    subnets: ${subnets}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
