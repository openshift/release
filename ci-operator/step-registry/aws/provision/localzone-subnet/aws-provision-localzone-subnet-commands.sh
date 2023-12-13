#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Save stacks events
trap 'save_stack_events_to_artifacts' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"

function save_stack_events_to_artifacts()
{
  set +o errexit
  aws --region ${REGION} cloudformation describe-stack-events --stack-name ${STACK_NAME} --output json > "${ARTIFACT_DIR}/stack-events-${STACK_NAME}.json"
  set -o errexit
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function aws_add_param_to_json() {
    local k="$1"
    local v="$2"
    local param_json="$3"
    if [ ! -e "$param_json" ]; then
        echo -n '[]' > "$param_json"
    fi
    cat <<< "$(jq  --arg k "$k" --arg v "$v" '. += [{"ParameterKey":$k, "ParameterValue":$v}]' "$param_json")" > "$param_json"
}

function aws_describe_stack() {
    local aws_region=$1
    local stack_name=$2
    local output_json="$3"
    cmd="aws --region ${aws_region} cloudformation describe-stacks --stack-name ${stack_name} > '${output_json}'"
    run_command "${cmd}" &
    wait "$!" || return 1
    return 0
}

function aws_create_stack() {
    local aws_region=$1
    local stack_name=$2
    local template_body="$3"
    local parameters="$4"
    local options="$5"
    local output_json="$6"

    cmd="aws --region ${aws_region} cloudformation create-stack --stack-name ${stack_name} ${options} --template-body '${template_body}' --parameters '${parameters}'"
    run_command "${cmd}" &
    wait "$!" || return 1

    cmd="aws --region ${aws_region} cloudformation wait stack-create-complete --stack-name ${stack_name}"
    run_command "${cmd}" &
    wait "$!" || return 1

    aws_describe_stack ${aws_region} ${stack_name} "$output_json" &
    wait "$!" || return 1

    return 0
}

localzone_subnet_tpl="/tmp/localzone_subnet_tpl.yaml"

cat > ${localzone_subnet_tpl} << EOF
# CloudFormation template used to create Local Zone subnets and dependencies
AWSTemplateFormatVersion: 2010-09-09
Description: Template for Best Practice VPC with 1-3 AZs

Parameters:
  ClusterName:
    Description: ClusterName used to prefix resource names
    Type: String
  VpcId:
    Description: VPC Id
    Type: String
  LocalZoneName:
    Description: Local Zone Name (Example us-east-1-bos-1)
    Type: String
  RouteTableId:
    Description: Route Table ID to associate the Local Zone subnet
    Type: String
  SubnetCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.128.0/20
    Description: CIDR block for Subnet
    Type: String

Resources:
  LocalZoneSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VpcId
      CidrBlock: !Ref SubnetCidr
      AvailabilityZone: !Ref LocalZoneName
      Tags:
      - Key: Name
        Value: !Join
          - ""
          - [ !Ref ClusterName, !Ref LocalZoneName, "-1" ]
      - Key: kubernetes.io/cluster/unmanaged
        Value: "true"

  SubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref LocalZoneSubnet
      RouteTableId: !Ref RouteTableId

Outputs:
  SubnetId:
    Description: Subnet ID.
    Value: !Ref LocalZoneSubnet
EOF

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

# first private subnet
if [[ "${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP}" == "yes" ]]; then
  localzone_parent_subnet=$(yq-go r "${SHARED_DIR}/public_subnet_ids" '[0]')
else
  localzone_parent_subnet=$(yq-go r "${SHARED_DIR}/private_subnet_ids" '[0]')
fi

vpc_id=$(head -n 1 "${SHARED_DIR}/vpc_id")

if [[ "$vpc_id" == "" ]] || [[ "$vpc_id" == "null" ]] || [[ "$localzone_parent_subnet" == "" ]] || [[ "$localzone_parent_subnet" == "null" ]]; then
    echo "ERROR: Can not find VPC or parent subnet, exit now."
    exit 1
fi

az_name=$(aws --region $REGION ec2 describe-subnets --subnet-ids $localzone_parent_subnet | jq -r '.Subnets[0].AvailabilityZone')
local_az_name=$(aws --region $REGION ec2 describe-availability-zones --filters Name=opt-in-status,Values=opted-in Name=zone-type,Values=local-zone | jq -r --arg z $az_name '[.AvailabilityZones[] | select (.ParentZoneName==$z)] | .[0].ZoneName')
echo $local_az_name > "${SHARED_DIR}"/edge-zone-name.txt

route_table_id=$(aws --region $REGION ec2 describe-route-tables --filter Name=association.subnet-id,Values=$localzone_parent_subnet | jq -r .RouteTables[].RouteTableId)

echo "localzone_parent_subnet: $localzone_parent_subnet"
echo "az_name: $az_name"
echo "local_az_name: $local_az_name"
echo "route_table_id: $route_table_id"


if [[ "$az_name" == "" ]] || [[ "$local_az_name" == "" ]] || [[ "$route_table_id" == "" ]]\
   || [[ "$az_name" == "null" ]] || [[ "$local_az_name" == "null" ]] || [[ "$route_table_id" == "null" ]]; then
    echo "ERROR: az_name or local_az_name or route_table_id is empty."
    exit 1
fi


STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-localzone"
# save stack information to ${SHARED_DIR} for deprovision step
echo ${STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
extra_options=" "
localzone_subnet_output="$ARTIFACT_DIR/localzone_subnet_output.json"
localzone_subnet_params="$ARTIFACT_DIR/localzone_subnet_params.json"

aws_add_param_to_json "ClusterName" ${CLUSTER_NAME} "$localzone_subnet_params"
aws_add_param_to_json "VpcId" ${vpc_id} "$localzone_subnet_params"
aws_add_param_to_json "LocalZoneName" ${local_az_name} "$localzone_subnet_params"
aws_add_param_to_json "RouteTableId" ${route_table_id} "$localzone_subnet_params"
aws_add_param_to_json "SubnetCidr" "10.0.128.0/20" "$localzone_subnet_params"
aws_create_stack ${REGION} ${STACK_NAME} "file://${localzone_subnet_tpl}" "file://${localzone_subnet_params}" "${extra_options}" "${localzone_subnet_output}"

localzone_subnet=$(jq -j '.Stacks[].Outputs[] | select(.OutputKey=="SubnetId") | .OutputValue' "$localzone_subnet_output")
echo $localzone_subnet > $SHARED_DIR/localzone_subnet_id
echo $local_az_name > $SHARED_DIR/localzone_az_name
echo "localzone_subnet: $localzone_subnet"

if [ X"$localzone_subnet" == X"" ] || [ X"$localzone_subnet" == X"null" ]; then
    echo "ERROR: Failed to create local zone, localzone_subnet is empty, exit now."
    exit 1
fi

# save stack output
aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > "${SHARED_DIR}/localzone_subnet_stack_output"

cp "${SHARED_DIR}/localzone_subnet_id" "${ARTIFACT_DIR}/"
cp "${SHARED_DIR}/localzone_az_name" "${ARTIFACT_DIR}/"
