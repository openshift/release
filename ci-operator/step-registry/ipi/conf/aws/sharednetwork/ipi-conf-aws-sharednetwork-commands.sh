#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

ls -la "${SHARED_DIR}"

declare -x STACK_NAME_VPC
declare -x STACK_NAME_LOCALZONE

TEMPLATE_SRC_REPO=https://raw.githubusercontent.com/openshift/installer/master/upi/aws/cloudformation

TEMPLATE_STACK_VPC="01_vpc.yaml"
TEMPLATE_STACK_LOCALZONE="01.99_net_local-zone.yaml"

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-sharednetwork.yaml.patch

REGION="${LEASED_RESOURCE}"

CLUSTER_NAME="$(yq-go r "${CONFIG}" 'metadata.name')"

function join_by { local IFS="$1"; shift; echo "$*"; }

function add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

function get_template() {
  local template_file=$1; shift
  local template=${SHARED_DIR}/$template_file
  if [[ -f ${template} ]]; then
    echo "Using CloudFormation template from image. Path: ${template}"
  else
    echo "Downloading CloudFormation template from installer repo"
    curl -L ${TEMPLATE_SRC_REPO}/"${template_file}" -o "${template}"
  fi
}

function wait_for_stack() {
  stack_name=$1

  echo "Waiting for stack create stack complete: ${stack_name}"
  aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}" &
  wait "$!"
  echo "Waited for stack ${stack_name} completed"

  stack_status=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" | jq -r .Stacks[0].StackStatus)
  if [[ "$stack_status" != "CREATE_COMPLETE" ]]; then
    echo "Detected Failed Stack deployment with status: [${stack_status}]"

    echo "Collecting stack events before failing:"
    aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${stack_name}" \
      | jq -c '.StackEvents[] | select(.ResourceStatus | contains("CREATE_FAILED","ROLLBACK_IN_PROGRESS")) \
                | [.Timestamp, .StackName, .ResourceType, .ResourceStatus, .ResourceStatusReason]'
    exit 1
  fi
}

function deploy_stack() {
  local stack_name=$1; shift
  local template_name=$1;
  local vars_name="${template_name}.parameters.json"

  get_template "${stack_name}"

  echo "Creating CloudFormation stack ${stack_name} with template $template_name"
  set +e
  aws --region "${REGION}" cloudformation create-stack \
    --stack-name "${stack_name}" \
    --template-body file://"${SHARED_DIR}"/"${template_name}" \
    --tags "${TAGS}" \
    --parameters file://"${SHARED_DIR}"/"${vars_name}"

  echo "Created stack: ${stack_name}"
  wait_for_stack "${stack_name}"
  set -e

  # save stack information to ${SHARED_DIR} for deprovision step
  echo "${stack_name}" >> "${SHARED_DIR}/deprovision_stacks"
}

create_stack_vpc() {
  # The above cloudformation template's max zones account is 3
  if [[ "${ZONES_COUNT}" -gt 3 ]]
  then
    ZONES_COUNT=3
  fi

  STACK_NAME_VPC="${CLUSTER_NAME}-shared-vpc"
  STACK_PARAMS_VPC="${SHARED_DIR}/${TEMPLATE_STACK_VPC}.parameters.json"
  add_param_to_json AvailabilityZoneCount "${ZONES_COUNT}" "${STACK_PARAMS_VPC}"
  deploy_stack "${STACK_NAME_VPC}" "${TEMPLATE_STACK_VPC}"
}

create_stack_localzones() {
  # Randomly select the Local Zone in the Region (to increase coverage of tested zones added automatically)
  localzone_name=$(< "${SHARED_DIR}"/local-zone-name.txt)
  echo "Local Zone selected: ${localzone_name}"

  vpc_rtb_pub=$(aws --region "$REGION" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="PublicRouteTableId").OutputValue')
  echo "VPC info: ${vpc_id} [public route table=${vpc_rtb_pub}]"

  STACK_PARAMS_LOCALZONE="${SHARED_DIR}/${TEMPLATE_STACK_LOCALZONE}.parameters.json"
  STACK_NAME_LOCALZONE="${CLUSTER_NAME}-${localzone_name}"
  add_param_to_json VpcId "${vpc_id}" "${STACK_PARAMS_LOCALZONE}"
  add_param_to_json PublicRouteTableId "${vpc_rtb_pub}" "${STACK_PARAMS_LOCALZONE}"
  add_param_to_json SubnetName "${CLUSTER_NAME}-public-${localzone_name}" "${STACK_PARAMS_LOCALZONE}"
  add_param_to_json ZoneName "${localzone_name}" "${STACK_PARAMS_LOCALZONE}"
  add_param_to_json PublicSubnetCidr "10.0.128.0/20" "${STACK_PARAMS_LOCALZONE}"
  deploy_stack "${STACK_NAME_LOCALZONE}" "${TEMPLATE_STACK_LOCALZONE}"
}

#
# Main
#

create_stack_vpc

subnets_arr="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]')"
echo "Subnets : ${subnets_arr}"

subnets=[]

vpc_id=$(aws --region "$REGION" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="VpcId").OutputValue')
echo "$vpc_id" > "${SHARED_DIR}/vpc_id"

if [[ -n "${AWS_EDGE_POOL_ENABLED-}" ]]; then
  create_stack_localzones

  subnet_lz=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME_LOCALZONE}" | jq -r .Stacks[0].Outputs[0].OutputValue)
  subnets_arr=$(jq -c ". + [\"$subnet_lz\"]" <(echo "$subnets_arr"))
  echo "Subnets (including local zones): ${subnets_arr}"
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
