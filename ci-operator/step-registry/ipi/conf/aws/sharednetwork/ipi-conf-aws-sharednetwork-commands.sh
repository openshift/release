#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

export TEMPLATE_BASE_PATH=https://raw.githubusercontent.com/openshift/installer/master/upi/aws/cloudformation
export TEMPLATE_STACK_VPC="01_vpc.yaml"
export TEMPLATE_STACK_LOCAL_ZONE="01.99_net_local-zone.yaml"

function join_by { local IFS="$1"; shift; echo "$*"; }

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-sharednetwork.yaml.patch

REGION="${LEASED_RESOURCE}"

CLUSTER_NAME="$(yq-go r "${CONFIG}" 'metadata.name')"

# The above cloudformation template's max zones account is 3
if [[ "${ZONES_COUNT}" -gt 3 ]]
then
  ZONES_COUNT=3
fi

echo "Downloading VPC CloudFormation template"
curl -L ${TEMPLATE_BASE_PATH}/${TEMPLATE_STACK_VPC} -o /tmp/${TEMPLATE_STACK_VPC}

echo "Creating VPC CloudFormation stack using template file $TEMPLATE_STACK_VPC"
STACK_NAME_VPC="${CLUSTER_NAME}-shared-vpc"
aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME_VPC}" \
  --template-body "$(cat /tmp/${TEMPLATE_STACK_VPC})" \
  --tags "${TAGS}" \
  --parameters "ParameterKey=AvailabilityZoneCount,ParameterValue=${ZONES_COUNT}" &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME_VPC}" &
wait "$!"
echo "Waited for stack"

subnets_arr="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]')"
echo "Subnets : ${subnets_arr}"

subnets=[]

# save stack information to ${SHARED_DIR} for deprovision step
echo "${STACK_NAME_VPC}" >> "${SHARED_DIR}/sharednetworkstackname"

vpc_id=$(aws --region "$REGION" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="VpcId").OutputValue')
echo "$vpc_id" > "${SHARED_DIR}/vpc_id"

if [[ -n "${AWS_EDGE_POOL_ENABLED-}" ]]; then

  echo "Downloading Local Zone CloudFormation template"
  curl -L ${TEMPLATE_BASE_PATH}/${TEMPLATE_STACK_LOCAL_ZONE} -o /tmp/${TEMPLATE_STACK_LOCAL_ZONE}

  # Randomly select the Local Zone in the Region (to increase coverage of tested zones added automatically)
  localzone_name=$(< "${SHARED_DIR}"/edge-zone-name.txt)
  echo "Local Zone selected: ${localzone_name}"

  vpc_rtb_pub=$(aws --region $REGION cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="PublicRouteTableId").OutputValue')
  echo "VPC info: ${vpc_id} [public route table=${vpc_rtb_pub}]"

  echo "Creating Local Zone subnet CloudFormation stack using template file $TEMPLATE_STACK_LOCAL_ZONE"
  stack_name_localzone="${CLUSTER_NAME}-${localzone_name}"
  aws --region "${REGION}" cloudformation create-stack \
    --stack-name "${stack_name_localzone}" \
    --template-body "$(cat /tmp/${TEMPLATE_STACK_LOCAL_ZONE})" \
    --tags "${TAGS}" \
    --parameters \
      ParameterKey=VpcId,ParameterValue="${vpc_id}" \
      ParameterKey=PublicRouteTableId,ParameterValue="${vpc_rtb_pub}" \
      ParameterKey=SubnetName,ParameterValue="${CLUSTER_NAME}-public-${localzone_name}" \
      ParameterKey=ZoneName,ParameterValue="${localzone_name}" \
      ParameterKey=PublicSubnetCidr,ParameterValue="10.0.128.0/20" &
  
  wait "$!"
  echo "Created stack ${stack_name_localzone}"

  aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name_localzone}" &
  wait "$!"
  echo "Waited for stack ${stack_name_localzone}"

  stack_status=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name_localzone}" | jq -r .Stacks[0].StackStatus)
  if [[ "$stack_status" != "CREATE_COMPLETE" ]]; then
    echo "Detected Failed Stack deployment with status: [${stack_status}]"
    exit 1
  fi

  subnet_lz=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name_localzone}" | jq -r .Stacks[0].Outputs[0].OutputValue)
  subnets_arr=$(jq -c ". + [\"$subnet_lz\"]" <(echo "$subnets_arr"))
  echo "Subnets (including local zones): ${subnets_arr}"

  echo "${stack_name_localzone}" >> "${SHARED_DIR}/sharednetwork_stackname_localzone"
fi

# Converting for a valid format to install-config.yaml
subnets=${subnets_arr//\"/\'}
echo "Subnets config : ${subnets}"

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
