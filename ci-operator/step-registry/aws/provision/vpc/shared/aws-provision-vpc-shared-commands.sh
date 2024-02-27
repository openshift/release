#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Save stacks events
trap 'save_stack_events_to_artifacts' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  CLUSTER_CREATOR_USER_ARN=$(aws sts get-caller-identity | jq -r '.Arn')
  CLUSTER_CREATOR_AWS_ACCOUNT_NO=$(echo $CLUSTER_CREATOR_USER_ARN | awk -F ":" '{print $5}')
  echo "Using shared account, cluster creator account: ${CLUSTER_CREATOR_AWS_ACCOUNT_NO:0:6}***"
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
fi

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

REGION=${REGION:-$LEASED_RESOURCE}

function save_stack_events_to_artifacts()
{
  set +o errexit
  aws --region ${REGION} cloudformation describe-stack-events --stack-name ${STACK_NAME} --output json > "${ARTIFACT_DIR}/stack-events-${STACK_NAME}.json"
  set -o errexit
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

cat > /tmp/01_vpc.yaml << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for Best Practice VPC with 1-3 AZs

Parameters:
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.0.0/16
    Description: CIDR block for VPC.
    Type: String
  CidrCount:
    ConstraintDescription: The number of CIDRs to generate, used by Cloudformation function "Cidr"
    Description: The number of CIDRs to generate, used by Cloudformation function "Cidr"
    Type: String
    Default: "6"
  AvailabilityZoneCount:
    ConstraintDescription: "The number of availability zones. (Min: 1, Max: 3)"
    MinValue: 1
    MaxValue: 3
    Default: 1
    Description: "How many AZs to create VPC subnets for. (Min: 1, Max: 3)"
    Type: Number
  SubnetBits:
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/19-27.
    MinValue: 5
    MaxValue: 13
    Default: 12
    Description: "Size of each subnet to create within the availability zones. (Min: 5 = /27, Max: 13 = /19)"
    Type: Number
  DhcpOptionSet:
    Default: "no"
    AllowedValues:
    - "yes"
    - "no"
    Description: "Create a dhcpOptionSet with a custom DNS name"
    Type: String
  AllowedAvailabilityZoneList:
    ConstraintDescription: "Select AZs from this list, e.g. 'us-east-2c,us-east-2a'"
    Type: CommaDelimitedList
    Default: ""
  OutpostArn:
    ConstraintDescription: The Amazon Resource Name (ARN) of the Outpost.
    Description: The Amazon Resource Name (ARN) of the Outpost.
    Type: String
    Default: ""
  OutpostAz:
    ConstraintDescription: The AZ of the Outpost.
    Description: The AZ of the Outpost.
    Type: String
    Default: ""
  ResourceSharePrincipals:
    ConstraintDescription: ResourceSharePrincipals
    Default: ""
    Description: "ResourceSharePrincipals"
    Type: String

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Network Configuration"
      Parameters:
      - VpcCidr
      - SubnetBits
    - Label:
        default: "Availability Zones"
      Parameters:
      - AvailabilityZoneCount
    ParameterLabels:
      AvailabilityZoneCount:
        default: "Availability Zone Count"
      VpcCidr:
        default: "VPC CIDR"
      SubnetBits:
        default: "Bits Per Subnet"

Conditions:
  DoAz3: !Equals [3, !Ref AvailabilityZoneCount]
  DoAz2: !Or [!Equals [2, !Ref AvailabilityZoneCount], Condition: DoAz3]
  DoDhcp: !Equals ["yes", !Ref DhcpOptionSet]
  AzRestriction: !Not [ !Equals [!Join ['', !Ref AllowedAvailabilityZoneList], ''] ]
  DoOutpost: !Not [ !Equals [!Ref OutpostArn, ''] ]
  ShareSubnets: !Not [ !Equals ['', !Ref ResourceSharePrincipals] ]

Resources:
  VPC:
    Type: "AWS::EC2::VPC"
    Properties:
      EnableDnsSupport: "true"
      EnableDnsHostnames: "true"
      CidrBlock: !Ref VpcCidr
      Tags:
      - Key: Name
        Value: !Join [ "-", [ !Ref "AWS::StackName", "cf" ] ]
  PublicSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, !Ref CidrCount, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet2:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, !Ref CidrCount, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [1, !Ref AllowedAvailabilityZoneList ],
              !Select [1, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet3:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, !Ref CidrCount, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [2, !Ref AllowedAvailabilityZoneList ],
              !Select [2, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  InternetGateway:
    Type: "AWS::EC2::InternetGateway"
  GatewayToInternet:
    Type: "AWS::EC2::VPCGatewayAttachment"
    Properties:
      VpcId: !Ref VPC
      InternetGatewayId: !Ref InternetGateway
  PublicRouteTable:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  PublicRoute:
    Type: "AWS::EC2::Route"
    DependsOn: GatewayToInternet
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway
  PublicSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref PublicRouteTable
  PublicSubnetRouteTableAssociation2:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz2
    Properties:
      SubnetId: !Ref PublicSubnet2
      RouteTableId: !Ref PublicRouteTable
  PublicSubnetRouteTableAssociation3:
    Condition: DoAz3
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnet3
      RouteTableId: !Ref PublicRouteTable
  PrivateSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, !Ref CidrCount, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PrivateSubnet
      RouteTableId: !Ref PrivateRouteTable
  NAT:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP
        - AllocationId
      SubnetId: !Ref PublicSubnet
  EIP:
    Type: "AWS::EC2::EIP"
    Properties:
      Domain: vpc
  Route:
    Type: "AWS::EC2::Route"
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT
  PrivateSubnet2:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, !Ref CidrCount, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [1, !Ref AllowedAvailabilityZoneList ],
              !Select [1, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable2:
    Type: "AWS::EC2::RouteTable"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation2:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz2
    Properties:
      SubnetId: !Ref PrivateSubnet2
      RouteTableId: !Ref PrivateRouteTable2
  NAT2:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz2
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP2
        - AllocationId
      SubnetId: !Ref PublicSubnet2
  EIP2:
    Type: "AWS::EC2::EIP"
    Condition: DoAz2
    Properties:
      Domain: vpc
  Route2:
    Type: "AWS::EC2::Route"
    Condition: DoAz2
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable2
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT2
  PrivateSubnet3:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, !Ref CidrCount, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [2, !Ref AllowedAvailabilityZoneList ],
              !Select [2, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable3:
    Type: "AWS::EC2::RouteTable"
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation3:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz3
    Properties:
      SubnetId: !Ref PrivateSubnet3
      RouteTableId: !Ref PrivateRouteTable3
  NAT3:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz3
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP3
        - AllocationId
      SubnetId: !Ref PublicSubnet3
  EIP3:
    Type: "AWS::EC2::EIP"
    Condition: DoAz3
    Properties:
      Domain: vpc
  Route3:
    Type: "AWS::EC2::Route"
    Condition: DoAz3
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable3
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT3
  PublicSubnetOutpost:
    Type: "AWS::EC2::Subnet"
    Condition: DoOutpost
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [6, !Cidr [!Ref VpcCidr, !Ref CidrCount, !Ref SubnetBits]]
      AvailabilityZone: !Ref OutpostAz
      OutpostArn: !Ref OutpostArn
      Tags:
      - Key: Name
        Value: !Join [ "-", [ !Ref "AWS::StackName", "Outpost-PublicSubnet" ] ]
      - Key: "kubernetes.io/cluster/outpost-tag"
        Value: "owned"
  EIPOutpost:
    Type: "AWS::EC2::EIP"
    Condition: DoOutpost
    DependsOn: GatewayToInternet
    Properties:
      Domain: vpc
  NATOutpost:
    Type: "AWS::EC2::NatGateway"
    Condition: DoOutpost
    DependsOn:
    - EIPOutpost
    - PublicSubnetOutpost
    Properties:
      AllocationId: !GetAtt EIPOutpost.AllocationId
      SubnetId: !Ref PublicSubnetOutpost
      Tags:
      - Key: Name
        Value: !Join [ "-", [ !Ref "AWS::StackName", "Outpost-NatGateway" ] ]
  PublicSubnetRouteTableAssociationOutpost:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoOutpost
    Properties:
      SubnetId: !Ref PublicSubnetOutpost
      RouteTableId: !Ref PublicRouteTable
  PrivateSubnetOutpost:
    Type: "AWS::EC2::Subnet"
    Condition: DoOutpost
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [7, !Cidr [!Ref VpcCidr, !Ref CidrCount, !Ref SubnetBits]]
      AvailabilityZone: !Ref OutpostAz
      OutpostArn: !Ref OutpostArn
      Tags:
        - Key: Name
          Value: !Join [ "-", [ !Ref "AWS::StackName", "Outpost-PrivateSubnet" ] ]
  PrivateRouteTableOutpost:
    Type: "AWS::EC2::RouteTable"
    Condition: DoOutpost
    Properties:
      VpcId: !Ref VPC
      Tags:
        - Key: Name
          Value: !Join [ "-", [ !Ref "AWS::StackName", "Outpost-PrivateRouteTable" ] ]
  RouteOutpost:
    Type: "AWS::EC2::Route"
    Condition: DoOutpost
    Properties:
      RouteTableId: !Ref PrivateRouteTableOutpost
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NATOutpost
  PrivateSubnetRouteTableAssociationOutpost:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoOutpost
    Properties:
      SubnetId: !Ref PrivateSubnetOutpost
      RouteTableId: !Ref PrivateRouteTableOutpost
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
      - !Ref PrivateRouteTable
      - !If [DoAz2, !Ref PrivateRouteTable2, !Ref "AWS::NoValue"]
      - !If [DoAz3, !Ref PrivateRouteTable3, !Ref "AWS::NoValue"]
      - !If [DoOutpost, !Ref PrivateRouteTableOutpost, !Ref "AWS::NoValue"]
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .s3
      VpcId: !Ref VPC
  DhcpOptions:
    Type: AWS::EC2::DHCPOptions
    Condition: DoDhcp
    Properties:
        DomainName: example.com
        DomainNameServers:
          - AmazonProvidedDNS
  VPCDHCPOptionsAssociation:
    Type: AWS::EC2::VPCDHCPOptionsAssociation
    Condition: DoDhcp
    Properties:
      VpcId: !Ref VPC
      DhcpOptionsId: !Ref DhcpOptions
  ResourceShareSubnets:
    Type: "AWS::RAM::ResourceShare"
    Condition: ShareSubnets
    Properties:
      Name: !Join [ "-", [ !Ref "AWS::StackName", "resource-share" ] ]
      ResourceArns:
        - !Join
            - ''
            - [ 'arn:', !Ref "AWS::Partition", ':ec2:', !Ref 'AWS::Region', ':', !Ref 'AWS::AccountId', ':subnet/', !Ref PrivateSubnet ]
        - !Join
            - ''
            - [ 'arn:', !Ref "AWS::Partition", ':ec2:', !Ref 'AWS::Region', ':', !Ref 'AWS::AccountId', ':subnet/', !Ref PublicSubnet ]
        - !If
            - DoAz2
            - !Join
              - ''
              - [ 'arn:', !Ref "AWS::Partition", ':ec2:', !Ref 'AWS::Region', ':', !Ref 'AWS::AccountId', ':subnet/', !Ref PrivateSubnet2 ]
            - !Ref "AWS::NoValue"
        - !If
            - DoAz2
            - !Join
              - ''
              - [ 'arn:', !Ref "AWS::Partition", ':ec2:', !Ref 'AWS::Region', ':', !Ref 'AWS::AccountId', ':subnet/', !Ref PublicSubnet2 ]
            - !Ref "AWS::NoValue"
        - !If
            - DoAz3
            - !Join
              - ''
              - [ 'arn:', !Ref "AWS::Partition", ':ec2:', !Ref 'AWS::Region', ':', !Ref 'AWS::AccountId', ':subnet/', !Ref PrivateSubnet3 ]
            - !Ref "AWS::NoValue"
        - !If
            - DoAz3
            - !Join
              - ''
              - [ 'arn:', !Ref "AWS::Partition", ':ec2:', !Ref 'AWS::Region', ':', !Ref 'AWS::AccountId', ':subnet/', !Ref PublicSubnet3 ]
            - !Ref "AWS::NoValue"
      Principals:
        - !Ref ResourceSharePrincipals
      Tags:
        - Key: Name
          Value: !Join [ "-", [ !Ref "AWS::StackName", "resource-share" ] ]

Outputs:
  VpcId:
    Description: ID of the new VPC.
    Value: !Ref VPC
  PublicSubnetIds:
    Description: Subnet IDs of the public subnets.
    Value:
      !Join [
        ",",
        [!Ref PublicSubnet, !If [DoAz2, !Ref PublicSubnet2, !Ref "AWS::NoValue"], !If [DoAz3, !Ref PublicSubnet3, !Ref "AWS::NoValue"]]
      ]
  PrivateSubnetIds:
    Description: Subnet IDs of the private subnets.
    Value:
      !Join [
        ",",
        [!Ref PrivateSubnet, !If [DoAz2, !Ref PrivateSubnet2, !Ref "AWS::NoValue"], !If [DoAz3, !Ref PrivateSubnet3, !Ref "AWS::NoValue"]]
      ]
  PublicRouteTableId:
    Description: Public Route table ID
    Value: !Ref PublicRouteTable
  PrivateRouteTableIds:
    Description: Private Route table IDs
    Value:
      !Join [
        ",",
        [
          !If [
              "AzRestriction",
              !Join ["=", [!Select [0, !Ref AllowedAvailabilityZoneList], !Ref PrivateRouteTable]],
              !Join ["=", [!Select [0, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable]]
          ],
          !If [DoAz2,
                !If [
                  "AzRestriction",
                  !Join ["=", [!Select [1, !Ref AllowedAvailabilityZoneList], !Ref PrivateRouteTable2]],
                  !Join ["=", [!Select [1, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable2]]
                ],
               !Ref "AWS::NoValue"
          ],
          !If [DoAz3,
               !If [
                  "AzRestriction",
                  !Join ["=", [!Select [2, !Ref AllowedAvailabilityZoneList], !Ref PrivateRouteTable3]],
                  !Join ["=", [!Select [2, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable3]]
                ],
               !Ref "AWS::NoValue"
          ]
        ]
      ]
  OutpostPublicSubnetId:
    Description: Public Subnet ID in Outpost
    Condition: DoOutpost
    Value: !Ref PublicSubnetOutpost
  OutpostPrivateSubnetId:
    Description: Private Subnet ID in Outpost
    Condition: DoOutpost
    Value: !Ref PrivateSubnetOutpost
EOF

MAX_ZONES_COUNT=$(aws --region "${REGION}" ec2 describe-availability-zones --filter Name=state,Values=available Name=zone-type,Values=availability-zone | jq '.AvailabilityZones | length')
if (( ZONES_COUNT > MAX_ZONES_COUNT )); then
  ZONES_COUNT=$MAX_ZONES_COUNT
fi

# The above cloudformation template's max zones account is 3
if [[ "${ZONES_COUNT}" -gt 3 ]]
then
  ZONES_COUNT=3
fi

STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-vpc"
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  echo ${STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list_shared_account"
else
  echo ${STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
fi

vpc_params="${ARTIFACT_DIR}/vpc_params.json"
aws_add_param_to_json "AvailabilityZoneCount" ${ZONES_COUNT} "$vpc_params"
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  aws_add_param_to_json "ResourceSharePrincipals" ${CLUSTER_CREATOR_AWS_ACCOUNT_NO} "$vpc_params"
fi

if [[ ${CREATE_AWS_OUTPOST_SUBNETS} == "yes" ]]; then
  outpost_arn=$(jq -r '.OutpostArn' ${CLUSTER_PROFILE_DIR}/aws_outpost_info.json)
  outpost_az=$(jq -r '.AvailabilityZone' ${CLUSTER_PROFILE_DIR}/aws_outpost_info.json)
  aws_add_param_to_json "CidrCount" "8" "$vpc_params"
  aws_add_param_to_json "OutpostArn" "${outpost_arn}" "$vpc_params"
  aws_add_param_to_json "OutpostAz" "${outpost_az}" "$vpc_params"
fi

if [[ ${ZONES_LIST} != "" ]]; then
  zones_list_count=$(echo "$ZONES_LIST" | awk -F',' '{ print NF }')
  if [[ "${zones_list_count}" != "${ZONES_COUNT}" ]]; then
    echo "ERROR: ${zones_list_count} zones in the list [${ZONES_LIST}], the zone count in the list should be the same as ZONES_COUNT: ${ZONES_COUNT}, exit now"
    exit 1
  fi
  aws_add_param_to_json "AllowedAvailabilityZoneList" "${ZONES_LIST}" "$vpc_params"
fi

aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat /tmp/01_vpc.yaml)" \
  --tags "${TAGS}" \
  --parameters file://${vpc_params} &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Waited for stack"

# save stack information to ${SHARED_DIR} for deprovision step
echo "${STACK_NAME}" > "${SHARED_DIR}/vpc_stack_name"

# save vpc stack output
aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > "${SHARED_DIR}/vpc_stack_output"

# save vpc id
# e.g. 
#   vpc-01739b6510a152d44
VpcId=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="VpcId") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
echo "$VpcId" > "${SHARED_DIR}/vpc_id"
echo "VpcId: ${VpcId}"

# all subnets
# ['subnet-pub1', 'subnet-pub2', 'subnet-priv1', 'subnet-priv2']
AllSubnetsIds="$(jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]' "${SHARED_DIR}/vpc_stack_output" | sed "s/\"/'/g")"
echo "$AllSubnetsIds" > "${SHARED_DIR}/subnet_ids"

# save public subnets ids
# ['subnet-pub1', 'subnet-pub2']
PublicSubnetIds="$(jq -c '[.Stacks[].Outputs[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue | split(",")[]]' "${SHARED_DIR}/vpc_stack_output" | sed "s/\"/'/g")"
echo "$PublicSubnetIds" > "${SHARED_DIR}/public_subnet_ids"
echo "PublicSubnetIds: ${PublicSubnetIds}"

# save private subnets ids
# ['subnet-priv1', 'subnet-priv2']
PrivateSubnetIds="$(jq -c '[.Stacks[].Outputs[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue | split(",")[]]' "${SHARED_DIR}/vpc_stack_output" | sed "s/\"/'/g")"
echo "$PrivateSubnetIds" > "${SHARED_DIR}/private_subnet_ids"
echo "PrivateSubnetIds: ${PrivateSubnetIds}"

# save AZs
#  ["us-east-2a","us-east-2b"]
all_ids=$(jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]' "${SHARED_DIR}/vpc_stack_output" | jq -r '. | join(" ")')
AvailabilityZones=$(aws --region "${REGION}" ec2 describe-subnets --subnet-ids ${all_ids} | jq -c '[.Subnets[].AvailabilityZone] | unique | sort')
echo "$AvailabilityZones" > "${SHARED_DIR}/availability_zones"
echo "AvailabilityZones: ${AvailabilityZones}"

# ***********************
# Route table ids are generally used by Local Zone and Wavelength Zone
# ***********************

# PublicRouteTableId
PublicRouteTableId=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PublicRouteTableId") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
echo "$PublicRouteTableId" > "${SHARED_DIR}/public_route_table_id"
echo "PublicRouteTableId: ${PublicRouteTableId}"

# PrivateRouteTableId
PrivateRouteTableId=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateRouteTableIds") | .OutputValue | split(",")[0] | split("=")[1]' "${SHARED_DIR}/vpc_stack_output")
echo "$PrivateRouteTableId" > "${SHARED_DIR}/private_route_table_id"
echo "PrivateRouteTableId: ${PrivateRouteTableId}"

# AWS Outpost
if [[ ${CREATE_AWS_OUTPOST_SUBNETS} == "yes" ]]; then
  o_pub_id=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="OutpostPublicSubnetId") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
  o_priv_id=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="OutpostPrivateSubnetId") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
  echo $o_pub_id > "${SHARED_DIR}/outpost_public_id"
  echo $o_priv_id > "${SHARED_DIR}/outpost_private_id"
  echo "outpost_public_id: ${o_pub_id}, outpost_private_id: ${o_priv_id}"
  echo "${outpost_az}" > "${SHARED_DIR}/outpost_availability_zone"
fi
