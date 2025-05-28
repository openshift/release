#!/bin/bash

#
# Step to create network resources required to install OpenShift
# in existing(BYO) VPC.
#

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"

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
  aws cloudformation wait stack-create-complete --stack-name "${stack_name}"

  echo_date "Stack ${stack_name} completed"

  stack_status=$(aws cloudformation describe-stacks --stack-name "${stack_name}" | jq -r '.Stacks[0].StackStatus // null')
  if [[ "$stack_status" != "CREATE_COMPLETE" ]]; then
    echo_date "Detected Failed Stack deployment with status: [${stack_status}]"

    echo_date "Collecting stack events before failing:"
    aws cloudformation describe-stack-events --stack-name "${stack_name}" --output json \
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
  if aws cloudformation create-stack \
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

  SUBNETS_STR="$(aws cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" \
    | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]')"
  echo "Subnets : ${SUBNETS_STR}"

  VPC_ID=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" \
    | jq -r '.Stacks[].Outputs[] | select(.OutputKey=="VpcId").OutputValue')
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
function create_stack_edge_subnet() {
  echo_date "Initializing CloudFormation Stack creation for VPC Subnets"

  edge_zone_name="$1"; shift
  subnet_cidr_priv="$1"; shift
  subnet_cidr_pub="$1";
  echo_date "Edge Zone selected: ${edge_zone_name}"

  zone_type=$(aws ec2 describe-availability-zones --zone-names "${edge_zone_name}" \
    --query 'AvailabilityZones[].ZoneType' --output text)
  echo_date "Discovering Public Route Table for zone type ${zone_type}"
  case $zone_type in
  "local-zone")
    vpc_rtb_pub=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" \
      | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="PublicRouteTableId").OutputValue' )
  ;;
  "wavelength-zone")
    vpc_rtb_pub=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME_CAGW-}" \
      | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="PublicRouteTableId").OutputValue' )
  ;;
  *) echo "unknow zone type for zone ${edge_zone_name}"; exit 1 ;;
  esac
  echo_date "Found Public Route Table: ${vpc_rtb_pub}"

  echo_date "Discovering Private Route Table from Stack: ${STACK_NAME_VPC}"
  #> Select the first route table from the list.
  vpc_rtb_priv=$(aws cloudformation describe-stacks \
    --stack-name "${STACK_NAME_VPC}" \
    | jq -r '.Stacks[0].Outputs[]
      | select(.OutputKey=="PrivateRouteTableIds").OutputValue
      | split(",")[0] | split("=")[1]')

  cat <<EOF
REGION=$REGION
VPC_ID=$VPC_ID
edge_zone_name=$edge_zone_name
vpc_rtb_pub=$vpc_rtb_pub
vpc_rtb_priv=$vpc_rtb_priv
subnet_cidr_pub=$subnet_cidr_pub
subnet_cidr_priv=$subnet_cidr_priv
EOF

  STACK_NAME_SUBNET=${CLUSTER_NAME}-subnets-${edge_zone_name/${REGION}-/}
  STACK_PARAMS_SUBNET="${TEMPLATE_DEST}/${TEMPLATE_STACK_SUBNET}.parameters.${edge_zone_name/${REGION}-/}.json"

  add_param_to_json VpcId "${VPC_ID}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json ClusterName "${CLUSTER_NAME}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json ZoneName "${edge_zone_name}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json PublicRouteTableId "${vpc_rtb_pub}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json PublicSubnetCidr "${subnet_cidr_pub}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json PrivateRouteTableId "${vpc_rtb_priv}" "${STACK_PARAMS_SUBNET}"
  add_param_to_json PrivateSubnetCidr "${subnet_cidr_priv}" "${STACK_PARAMS_SUBNET}"

  cp -rvf "${STACK_PARAMS_SUBNET}" "${TEMPLATE_DEST}/${TEMPLATE_STACK_SUBNET}.parameters.json"
  deploy_stack "${STACK_NAME_SUBNET}" "${TEMPLATE_STACK_SUBNET}"

  echo_date "Extracting and appending subnet ID from CloudFormation stack: ${STACK_NAME_SUBNET}"
  if [[ "${EDGE_PUBLIC_SUBNET-}" == "yes" ]]; then
    subnet_edge=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME_SUBNET}" \
      --query "Stacks[0].Outputs[?OutputKey=='PublicSubnetId'].OutputValue" \
      --output text)
    unmanaged_subnet=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME_SUBNET}" \
      --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetId'].OutputValue" \
      --output text)
  else
    subnet_edge=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME_SUBNET}" \
      --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetId'].OutputValue" \
      --output text)
    unmanaged_subnet=$(aws cloudformation describe-stacks --stack-name "${STACK_NAME_SUBNET}" \
      --query "Stacks[0].Outputs[?OutputKey=='PublicSubnetId'].OutputValue" \
      --output text)
  fi

  SUBNETS_STR=$(jq -c ". + [\"$subnet_edge\"]" <(echo "$SUBNETS_STR"))
  echo_date "Subnets (with edge zones): ${SUBNETS_STR}"

  echo_date "Setting unused subnet with required cluster tag by installer: ${unmanaged_subnet}"
  aws ec2 create-tags --resources "${unmanaged_subnet}" --tags "Key=kubernetes.io/cluster/unmanaged,Value=true" || \
    echo_date "WARNING: Failed to tag subnet ${unmanaged_subnet}"
  aws ec2 describe-subnets --filters Name=vpc-id,Values="${VPC_ID}" \
    | jq -c '.Subnets[] | {SubnetId, State, AvailabilityZoneId, AvailabilityZone, CidrBlock, Tags}' > ${ARTIFACT_DIR}/vpc-subnets.json || true
}

function create_edge_subnets() {
  base_net=192
  while IFS= read -r line; do
    echo_date "Setting up subnet creation for zone ${line}"
    cidr_private="10.0.${base_net}.0/24"
    base_net=$(( $base_net + 1 ))
    cidr_public="10.0.${base_net}.0/24"
    base_net=$(( $base_net + 1 ))

    create_stack_edge_subnet "${line}" "${cidr_private}" "${cidr_public}"
  done < <(grep -v '^$' < "${SHARED_DIR}"/edge-zone-names.txt)
}

#
# Main
#

create_stack_vpc

# Create network requirements for edge zones (Local Zone and Wavelength infrastructure).
# Those zones requires special deployment, such as:
# - Wavelength and Local Zones does not globally support NAT Gateways, all the private subnets in
#   those zone types will be associated with a private route table in the Region.
# - Resources in public subnets in Wavelength requires Public IP from a Carrier
#   Gateway, this resource must be created prior subnet creation, and public subnets into
#   those zones must be associated with the public route table with Carrier Gateway as default gateway.
if [[ "${AWS_EDGE_POOL_ENABLED-}" == "yes" ]]; then

  echo "EDGE_ZONE_TYPES=[${EDGE_ZONE_TYPES-}]"
  if [[ "${EDGE_ZONE_TYPES-}" == *"wavelength-zone"* ]]; then
    create_stack_carrier_gateway
  fi

  create_edge_subnets
fi

# Converting for a valid format to install-config.yaml
SUBNETS_CONFIG=[]
SUBNETS_CONFIG=${SUBNETS_STR//\"/\'}
echo_date "Subnets config: ${SUBNETS_CONFIG}"

# Generate availability zones from the region
mapfile -t AVAILABILITY_ZONES < <(aws ec2 describe-availability-zones \
  --filters Name=state,Values=available Name=zone-type,Values=availability-zone \
  | jq -r '.AvailabilityZones[].ZoneName' | sort -u)
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
EOF


RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_INITIAL:-}"
if [[ -z "${RELEASE_IMAGE_INSTALL}" ]]; then
  # If there is no initial release, we will be installing latest.
  RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_LATEST:-}"
fi
cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_INSTALL} -ojsonpath='{.metadata.version}' | cut -d. -f 1,2)
ocp_major_version=$(echo "${ocp_version}" | awk --field-separator=. '{print $1}')
ocp_minor_version=$(echo "${ocp_version}" | awk --field-separator=. '{print $2}')
rm /tmp/pull-secret
tmp_file=$(mktemp)

if ((ocp_major_version == 4 && ocp_minor_version <= 18)); then
  for s in $(echo "${SUBNETS_CONFIG}" | yq-go r - '[*]');
  do
    # platform.aws.subnets
    yq-go w -i ${PATCH} 'platform.aws.subnets[+]' "$s"
  done
else
  for s in $(echo "${SUBNETS_CONFIG}" | yq-go r - '[*]');
  do
    # platform.aws.vpc.subnets
    yq-go r -j ${PATCH} | jq --arg s $s '.platform.aws.vpc.subnets += [{"id": $s}]' | yq-go r - -P > ${tmp_file} && mv ${tmp_file} ${PATCH}
  done
fi

yq-go m -x -i "${CONFIG}" "${PATCH}"

echo "$VPC_ID" > "${SHARED_DIR}/vpc_id"
