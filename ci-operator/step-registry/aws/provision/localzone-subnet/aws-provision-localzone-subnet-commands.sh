#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

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

localzone_subnet_tpl="/tmp/01.99_net_local-zone.yaml"
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
          - "-"
          - [ !Ref ClusterName, !Ref LocalZoneName]
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

carrier_gateway_tpl="/tmp/01_vpc_01_carrier_gateway.yaml"
cat > ${carrier_gateway_tpl} << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for Creating Wavelength Zone Gateway (Carrier Gateway).

Parameters:
  VpcId:
    Description: VPC ID to associate the Carrier Gateway.
    Type: String
    AllowedPattern: ^(?:(?:vpc)(?:-[a-zA-Z0-9]+)?\b|(?:[0-9]{1,3}\.){3}[0-9]{1,3})$
    ConstraintDescription: VPC ID must be with valid name, starting with vpc-.*.
  ClusterName:
    Description: Cluster Name or Prefix name to prepend the tag Name for each subnet.
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: ClusterName parameter must be specified.

Resources:
  CarrierGateway:
    Type: "AWS::EC2::CarrierGateway"
    Properties:
      VpcId: !Ref VpcId
      Tags:
      - Key: Name
        Value: !Join ['-', [!Ref ClusterName, "cagw"]]

  PublicRouteTable:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VpcId
      Tags:
      - Key: Name
        Value: !Join ['-', [!Ref ClusterName, "public-carrier"]]

  PublicRoute:
    Type: "AWS::EC2::Route"
    DependsOn: CarrierGateway
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      CarrierGatewayId: !Ref CarrierGateway

  S3Endpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      PolicyDocument:
        Version: 2012-10-17
        Statement:
        - Effect: Allow
          Principal: '*'
          Action:
          - '*'
          Resource:
          - '*'
      RouteTableIds:
      - !Ref PublicRouteTable
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .s3
      VpcId: !Ref VpcId

Outputs:
  PublicRouteTableId:
    Description: Public Route table ID
    Value: !Ref PublicRouteTable
EOF

subnet_tpl="/tmp/01_vpc_99_subnet.yaml"
cat > ${subnet_tpl} << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for Best Practice Subnets (Public and Private)

Parameters:
  VpcId:
    Description: VPC ID which the subnets will be part.
    Type: String
    AllowedPattern: ^(?:(?:vpc)(?:-[a-zA-Z0-9]+)?\b|(?:[0-9]{1,3}\.){3}[0-9]{1,3})$
    ConstraintDescription: VPC ID must be with valid name, starting with vpc-.*.
  ClusterName:
    Description: Cluster Name or Prefix name to prepend the tag Name for each subnet.
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: ClusterName parameter must be specified.
  ZoneName:
    Description: Zone Name to create the subnets (Example us-west-2-lax-1a).
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: ZoneName parameter must be specified.
  PublicRouteTableId:
    Description: Public Route Table ID to associate the public subnet.
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: PublicRouteTableId parameter must be specified.
  PublicSubnetCidr:
    # yamllint disable-line rule:line-length
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.128.0/20
    Description: CIDR block for Public Subnet
    Type: String

  PrivateRouteTableId:
    Description: Public Route Table ID to associate the Local Zone subnet
    Type: String
    AllowedPattern: ".+"
    ConstraintDescription: PublicRouteTableId parameter must be specified.
  PrivateSubnetCidr:
    # yamllint disable-line rule:line-length
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.128.0/20
    Description: CIDR block for Public Subnet
    Type: String

Resources:
  PublicSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VpcId
      CidrBlock: !Ref PublicSubnetCidr
      AvailabilityZone: !Ref ZoneName
      Tags:
      - Key: Name
        Value: !Join ['-', [!Ref ClusterName, "public", !Ref ZoneName]]

  PublicSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref PublicRouteTableId

  PrivateSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VpcId
      CidrBlock: !Ref PrivateSubnetCidr
      AvailabilityZone: !Ref ZoneName
      Tags:
      - Key: Name
        Value: !Join ['-', [!Ref ClusterName, "private", !Ref ZoneName]]

  PrivateSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PrivateSubnet
      RouteTableId: !Ref PrivateRouteTableId

Outputs:
  PublicSubnetId:
    Description: Subnet ID of the public subnets.
    Value:
      !Join ["", [!Ref PublicSubnet]]

  PrivateSubnetId:
    Description: Subnet ID of the private subnets.
    Value:
      !Join ["", [!Ref PrivateSubnet]]
EOF


CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
VPC_ID=$(head -n 1 "${SHARED_DIR}/vpc_id")

if [[ ${EDGE_ZONE_TYPE} == "local-zone" ]]; then

  STACK_NAME="${CLUSTER_NAME}-localzone"
  # save stack information to ${SHARED_DIR} for deprovision step
  echo ${STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
  extra_options=" "
  localzone_subnet_output="$ARTIFACT_DIR/localzone_subnet_output.json"
  localzone_subnet_params="$ARTIFACT_DIR/localzone_subnet_params.json"

  localzone_name=$(head -n 1 "${SHARED_DIR}/edge-zone-name.txt")

  if [[ "${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP}" == "yes" ]]; then
    route_table_id=$(head -n 1 "${SHARED_DIR}/public_route_table_id")
  else
    route_table_id=$(head -n 1 "${SHARED_DIR}/private_route_table_id")
  fi
  

  aws_add_param_to_json "ClusterName" ${CLUSTER_NAME} "$localzone_subnet_params"
  aws_add_param_to_json "VpcId" ${VPC_ID} "$localzone_subnet_params"
  aws_add_param_to_json "LocalZoneName" ${localzone_name} "$localzone_subnet_params"
  aws_add_param_to_json "RouteTableId" ${route_table_id} "$localzone_subnet_params"
  aws_add_param_to_json "SubnetCidr" "10.0.128.0/20" "$localzone_subnet_params"
  aws_create_stack ${REGION} ${STACK_NAME} "file://${localzone_subnet_tpl}" "file://${localzone_subnet_params}" "${extra_options}" "${localzone_subnet_output}"

  cp $localzone_subnet_output "${SHARED_DIR}"/

  localzone_subnet=$(jq -j '.Stacks[].Outputs[] | select(.OutputKey=="SubnetId") | .OutputValue' "$localzone_subnet_output")
  echo $localzone_subnet > $SHARED_DIR/edge_zone_subnet_id
  echo "localzone_subnet: $localzone_subnet"

  if [ X"$localzone_subnet" == X"" ] || [ X"$localzone_subnet" == X"null" ]; then
      echo "ERROR: Failed to create local zone, localzone_subnet is empty, exit now."
      exit 1
  fi

elif [[ ${EDGE_ZONE_TYPE} == "wavelength-zone" ]]; then

  # Gateway
  STACK_NAME="${CLUSTER_NAME}-cagw"
  echo ${STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
  extra_options=" "
  cagw_gateway_output="$ARTIFACT_DIR/cagw_gateway_output.json"
  cagw_gateway_params="$ARTIFACT_DIR/cagw_gateway_params.json"

  aws_add_param_to_json "ClusterName" ${CLUSTER_NAME} "$cagw_gateway_params"
  aws_add_param_to_json "VpcId" ${VPC_ID} "$cagw_gateway_params"
  aws_create_stack ${REGION} ${STACK_NAME} "file://${carrier_gateway_tpl}" "file://${cagw_gateway_params}" "${extra_options}" "${cagw_gateway_output}"
  cp $cagw_gateway_output "${SHARED_DIR}"/

  cagw_route_table_id=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicRouteTableId") | .OutputValue' "${cagw_gateway_output}")
  if [ X"$cagw_route_table_id" == X"" ] || [ X"$cagw_route_table_id" == X"null" ]; then
    echo "ERROR: Failed to create Carrier Gateway, carrier gateway route table id is empty, exit now."
    exit 1
  fi

  # Subnet
  STACK_NAME="${CLUSTER_NAME}-wavelength-zone"
  echo ${STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
  extra_options=" "
  wavelengthzone_subnet_output="$ARTIFACT_DIR/wavelengthzone_subnet_output.json"
  wavelengthzone_subnet_params="$ARTIFACT_DIR/wavelengthzone_subnet_params.json"

  private_route_table_id=$(head -n 1 "${SHARED_DIR}/private_route_table_id")
  wavelengthzone_name=$(head -n 1 "${SHARED_DIR}/edge-zone-name.txt")
  priv_subnet_cidr="10.0.129.0/24"
  pub_subnet_cidr="10.0.128.0/24"

  aws_add_param_to_json "VpcId" ${VPC_ID} "$wavelengthzone_subnet_params"
  aws_add_param_to_json "ClusterName" ${CLUSTER_NAME} "$wavelengthzone_subnet_params"
  aws_add_param_to_json "ZoneName" ${wavelengthzone_name} "$wavelengthzone_subnet_params"
  aws_add_param_to_json "PublicRouteTableId" ${cagw_route_table_id} "$wavelengthzone_subnet_params"
  aws_add_param_to_json "PublicSubnetCidr" ${pub_subnet_cidr} "$wavelengthzone_subnet_params"
  aws_add_param_to_json "PrivateRouteTableId" ${private_route_table_id} "$wavelengthzone_subnet_params"
  aws_add_param_to_json "PrivateSubnetCidr" ${priv_subnet_cidr} "$wavelengthzone_subnet_params"
  aws_create_stack ${REGION} ${STACK_NAME} "file://${subnet_tpl}" "file://${wavelengthzone_subnet_params}" "${extra_options}" "${wavelengthzone_subnet_output}"
  cp $wavelengthzone_subnet_output "${SHARED_DIR}"/

  wavelengthzone_priv_subnet=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetId") | .OutputValue' "${wavelengthzone_subnet_output}")
  wavelengthzone_pub_subnet=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetId") | .OutputValue' "${wavelengthzone_subnet_output}")
  echo "Wavelength Zone Public Subnet ID: {wavelengthzone_pub_subnet}"
  echo "Wavelength Zone Private Subnet ID: {wavelengthzone_priv_subnet}"

  if [ X"$wavelengthzone_priv_subnet" == X"" ] || [ X"$wavelengthzone_priv_subnet" == X"null" ] || [ X"$wavelengthzone_pub_subnet" == X"" ] || [ X"$wavelengthzone_pub_subnet" == X"null" ]; then
      echo "ERROR: wavelength zone subnet is empty, exit now."
      exit 1
  fi
  if [[ "${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP}" == "yes" ]]; then
    echo $wavelengthzone_pub_subnet > $SHARED_DIR/edge_zone_subnet_id
  else
    echo $wavelengthzone_priv_subnet > $SHARED_DIR/edge_zone_subnet_id
  fi
else
  echo "ERROR: zone type ${EDGE_ZONE_TYPE} is not supported"
  exit 1
fi

set +x