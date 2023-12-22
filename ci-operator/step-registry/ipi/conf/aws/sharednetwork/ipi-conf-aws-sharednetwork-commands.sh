#!/bin/bash

#
# Step to create network resources required to install OpenShift
# in existing(BYO) VPC.
#

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-sharednetwork.yaml.patch

CLUSTER_NAME="$(yq-go r "${CONFIG}" 'metadata.name')"

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS=( "Key=expirationDate,Value=${EXPIRATION_DATE}" )
TAGS+=( "Key=ci-build-info,Value=${BUILD_ID}_${JOB_NAME}" )

declare -x VPC_ID
declare -x STACK_NAME_VPC
declare -x STACK_NAME_CAGW
declare -x STACK_NAME_SUBNET
declare -x STACK_NAME_LOCALZONE
declare -x SUBNETS_STR

TEMPLATE_DEST=${ARTIFACT_DIR}
TEMPLATE_SRC_REPO=https://raw.githubusercontent.com/openshift/installer/master/upi/aws/cloudformation
TEMPLATE_STACK_VPC="01_vpc.yaml"
TEMPLATE_STACK_CAGW="01_vpc_01_carrier_gateway.yaml"
TEMPLATE_STACK_SUBNET="01_vpc_99_subnet.yaml"
TEMPLATE_STACK_LOCALZONE="01.99_net_local-zone.yaml"

function join_by { local IFS="$1"; shift; echo "$*"; }

# echo prints a message with timestamp.
function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

# add_param_to_json Insert a parameter (Key/Value) in the CloudFormation Template parameter file.
function add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

# get_template download the CloudFormation Template from installer repository.
function get_template() {
  local template_file=$1
  local template_src="${TEMPLATE_SRC_REPO}/${template_file}"
  local template_dest="${TEMPLATE_DEST}/${template_file}"

  echo_date "Downloading CloudFormation template from [${template_src}] to [${template_dest}]"
  curl -L "${template_src}" -o "${template_dest}"
}

# wait_for_stack waits for the CloudFormation stack to be created.
function wait_for_stack() {
  stack_name=$1

  echo_date "Waiting to create stack complete: ${stack_name}"
  aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}"

  echo_date "Stack ${stack_name} completed"

  stack_status=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" | jq -r '.Stacks[0].StackStatus // null')
  if [[ "$stack_status" != "CREATE_COMPLETE" ]]; then
    echo_date "Detected Failed Stack deployment with status: [${stack_status}]"

    echo_date "Collecting stack events before failing:"
    aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${stack_name}" --output json \
      | tee "${ARTIFACT_DIR}/events_cfn_stack_${stack_name}.json"
    exit 1
  fi
}

# deploy_stack deploys the CloudFormation stack, waiting the creation.
function deploy_stack() {
  local stack_name=$1; shift
  local template_name=$1;
  local template_path="${TEMPLATE_DEST}/${template_name}"
  local parameters_path="${TEMPLATE_DEST}/${template_name}.parameters.json"

  echo_date "Initializing CloudFormation Stack creation"
  cat <<EOF
stack_name=$stack_name
template_path=$template_path
parameters_path=$parameters_path
EOF

  get_template "${template_name}"

  echo_date "Creating CloudFormation stack ${stack_name} with template $template_name"
  set +e
  if aws --region "${REGION}" cloudformation create-stack \
    --stack-name "${stack_name}" \
    --template-body file://"${template_path}" \
    --tags ${TAGS[*]} \
    --parameters file://"${parameters_path}"; then

    echo_date "Created stack: ${stack_name}"
    echo "${stack_name}" >> "${SHARED_DIR}/deprovision_stacks"

  else
    echo_date "ERROR when creating CloudFormation stack. Items to check:"
    echo "- Build log"
    echo "- CloudFormation Template: ARTIFACT_DIR/${template_name}"
    echo "- CloudFormation Template parameters: ARTIFACT_DIR/${template_name}.parameters.json"
  fi

  wait_for_stack "${stack_name}"
  set -e
}

# create_stack_vpc trigger the CloudFormation Stack creaion for VPC resources.
function create_stack_vpc() {
  echo_date "Initializing CloudFormation Stack creation for VPC"

  # The above cloudformation template's max zones account is 3
  if [[ "${ZONES_COUNT}" -gt 3 ]]
  then
    ZONES_COUNT=3
  fi

  STACK_NAME_VPC="${CLUSTER_NAME}-shared-vpc"
  STACK_PARAMS_VPC="${TEMPLATE_DEST}/${TEMPLATE_STACK_VPC}.parameters.json"

  add_param_to_json AvailabilityZoneCount "${ZONES_COUNT}" "${STACK_PARAMS_VPC}"
  deploy_stack "${STACK_NAME_VPC}" "${TEMPLATE_STACK_VPC}"

  SUBNETS_STR="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]')"
  echo "Subnets : ${SUBNETS_STR}"

  VPC_ID=$(aws --region "$REGION" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="VpcId").OutputValue')
}

# create_stack_vpc trigger the CloudFormation Stack creaion for LOcal Zone subnets.
function create_stack_localzone() {
  echo_date "Initializing CloudFormation Stack creation for Local Zone"

  # Randomly select the Local Zone in the Region (to increase coverage of tested zones added automatically)
  localzone_name=$(< "${SHARED_DIR}"/edge-zone-name.txt)
  echo_date "Local Zone selected: ${localzone_name}"

  vpc_rtb_pub=$(aws --region "$REGION" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" \
    | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="PublicRouteTableId").OutputValue')
  echo_date "VPC info: ${VPC_ID} [public route table=${vpc_rtb_pub}]"

  STACK_PARAMS_LOCALZONE="${TEMPLATE_DEST}/${TEMPLATE_STACK_LOCALZONE}.parameters.json"
  STACK_NAME_LOCALZONE="${CLUSTER_NAME}-${localzone_name}"

  add_param_to_json VpcId "${VPC_ID}" "${STACK_PARAMS_LOCALZONE}"
  add_param_to_json PublicRouteTableId "${vpc_rtb_pub}" "${STACK_PARAMS_LOCALZONE}"
  add_param_to_json SubnetName "${CLUSTER_NAME}-public-${localzone_name}" "${STACK_PARAMS_LOCALZONE}"
  add_param_to_json ZoneName "${localzone_name}" "${STACK_PARAMS_LOCALZONE}"
  add_param_to_json PublicSubnetCidr "10.0.128.0/20" "${STACK_PARAMS_LOCALZONE}"
  deploy_stack "${STACK_NAME_LOCALZONE}" "${TEMPLATE_STACK_LOCALZONE}"

  echo_date "Extracting and appending subnet ID from CloudFormation stack: ${STACK_NAME_LOCALZONE}"
  subnet_edge=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME_LOCALZONE}" | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetIds").OutputValue')

  SUBNETS_STR=$(jq -c ". + [\"$subnet_edge\"]" <(echo "$SUBNETS_STR"))
  echo_date "Subnets: ${SUBNETS_STR}"
}

function create_stack_carrier_gateway() {
  echo_date "Initializing CloudFormation Stack creation for VPC Carrier Gateway"

  STACK_PARAMS_CAGW="${TEMPLATE_DEST}/${TEMPLATE_STACK_CAGW}.parameters.json"
  STACK_NAME_CAGW=${CLUSTER_NAME}-cagw

  add_param_to_json VpcId "${VPC_ID}" "${STACK_PARAMS_CAGW}"
  add_param_to_json ClusterName "${CLUSTER_NAME}" "${STACK_PARAMS_CAGW}"
  deploy_stack "${STACK_NAME_CAGW}" "${TEMPLATE_STACK_CAGW}"
}

# create_stack_wavelength_subnets creates the CloudFormation stack to provision public
# and private subnets in Wavelength zone, discovering the private subnet ID to be
# used in the install-config.yaml.
function create_stack_wavelength_subnets() {
  echo_date "Initializing CloudFormation Stack creation for VPC Subnets"

  edge_zone_name=$(< "${SHARED_DIR}"/edge-zone-name.txt)
  echo_date "Edge Zone selected: ${edge_zone_name}"

  echo_date "Discovering Public Route Table from Stack: ${STACK_NAME_CAGW}"
  vpc_rtb_pub=$(aws --region "$REGION" cloudformation describe-stacks \
    --stack-name "${STACK_NAME_CAGW}" \
    | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="PublicRouteTableId").OutputValue' )

  echo_date "Discovering Private Route Table from Stack: ${STACK_NAME_VPC}"
  #> Select the first route table from the list.
  vpc_rtb_priv=$(aws --region "$REGION" cloudformation describe-stacks \
    --stack-name "${STACK_NAME_VPC}" \
    | jq -r '.Stacks[0].Outputs[]
      | select(.OutputKey=="PrivateRouteTableIds").OutputValue
      | split(",")[0] | split("=")[1]')

  subnet_cidr_pub="10.0.128.0/24"
  subnet_cidr_priv="10.0.129.0/24"

  cat <<EOF
REGION=$REGION
VPC_ID=$VPC_ID
edge_zone_name=$edge_zone_name
vpc_rtb_pub=$vpc_rtb_pub
vpc_rtb_priv=$vpc_rtb_priv
subnet_cidr_pub=$subnet_cidr_pub
subnet_cidr_priv=$subnet_cidr_priv
EOF

  STACK_PARAMS_SUBNET="${TEMPLATE_DEST}/${TEMPLATE_STACK_SUBNET}.parameters.json"
  STACK_NAME_SUBNET=${CLUSTER_NAME}-subnets-${edge_zone_name/${REGION}-/}

  add_param_to_json VpcId "${VPC_ID}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json ClusterName "${CLUSTER_NAME}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json ZoneName "${edge_zone_name}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json PublicRouteTableId "${vpc_rtb_pub}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json PublicSubnetCidr "${subnet_cidr_pub}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json PrivateRouteTableId "${vpc_rtb_priv}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json PrivateSubnetCidr "${subnet_cidr_priv}" "${STACK_PARAMS_SUBNET}"
  deploy_stack "${STACK_NAME_SUBNET}" "${TEMPLATE_STACK_SUBNET}"

  echo_date "Extracting and appending subnet ID from CloudFormation stack: ${STACK_NAME_SUBNET}"
  subnet_edge=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME_SUBNET}" --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetId'].OutputValue" --output text | tr ',' '\n')

  SUBNETS_STR=$(jq -c ". + [\"$subnet_edge\"]" <(echo "$SUBNETS_STR"))
  echo_date "Subnets (with edge zones): ${SUBNETS_STR}"
}

#
# Main
#

create_stack_vpc

# Create network requirements for edge zones.
if [[ "${AWS_EDGE_POOL_ENABLED-}" == "yes" ]]; then
  if [[ "${EDGE_ZONE_TYPE-}" == "wavelength-zone" ]]; then
    create_stack_carrier_gateway
    create_stack_wavelength_subnets
  else
    create_stack_localzone
  fi
fi

# Converting for a valid format to install-config.yaml
SUBNETS_CONFIG=[]
SUBNETS_CONFIG=${SUBNETS_STR//\"/\'}
echo_date "Subnets config: ${SUBNETS_CONFIG}"

# Generate availability zones from the region
mapfile -t AVAILABILITY_ZONES < <(aws --region "${REGION}" ec2 describe-availability-zones --filters Name=state,Values=available Name=zone-type,Values=availability-zone | jq -r '.AvailabilityZones[].ZoneName' | sort -u)
ZONES=("${AVAILABILITY_ZONES[@]:0:${ZONES_COUNT}}")
ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
echo_date "AWS region: ${REGION} (zones: ${ZONES_STR})"

cat > "${PATCH}" << EOF
controlPlane:
  platform:
    aws:
      zones: ${ZONES_STR}
compute:
- name: worker
  platform:
    aws:
      zones: ${ZONES_STR}
platform:
  aws:
    subnets: ${SUBNETS_CONFIG}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"

echo "$VPC_ID" > "${SHARED_DIR}/vpc_id"