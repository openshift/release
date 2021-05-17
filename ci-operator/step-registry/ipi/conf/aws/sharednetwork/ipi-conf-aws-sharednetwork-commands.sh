#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-sharednetwork.yaml.patch"

REGION="${LEASED_RESOURCE}"

CLUSTER_NAME="$(/tmp/yq r "${CONFIG}" 'metadata.name')"

curl -L https://raw.githubusercontent.com/openshift/installer/master/upi/aws/cloudformation/01_vpc.yaml -o /tmp/01_vpc.yaml

MAX_ZONES_COUNT="$(cat "${SHARED_DIR}/maxzonescount")"

ZONE_COUNT=3
if [[ "${MAX_ZONES_COUNT}" -lt 3 ]]
	
then
  ZONE_COUNT="${MAX_ZONES_COUNT}"
fi

STACK_NAME="${CLUSTER_NAME}-shared-vpc"
aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat /tmp/01_vpc.yaml)" \
  --tags "${TAGS}" \
  --parameters "ParameterKey=AvailabilityZoneCount,ParameterValue=${ZONE_COUNT}" &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Waited for stack"

subnets="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]' | sed "s/\"/'/g")"
echo "Subnets : ${subnets}"

# save stack information to ${SHARED_DIR} for deprovision step
echo "${STACK_NAME}" >> "${SHARED_DIR}/sharednetworkstackname"

cat >> "${PATCH}" << EOF
platform:
  aws:
    subnets: ${subnets}
EOF

/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
