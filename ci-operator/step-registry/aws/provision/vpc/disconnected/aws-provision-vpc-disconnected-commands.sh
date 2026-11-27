#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; save_stack_events_to_artifacts' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

REGION="${AWS_REGION_OVERWRITE:-${LEASED_RESOURCE}}"

# Stacks created by this step, as "<region>/<stack-name>" entries, so that the
# exit trap dumps events for every one of them and not only the last.
CREATED_STACKS=""

function save_stack_events_to_artifacts()
{
  set +o errexit
  local entry stack_region stack_name
  for entry in ${CREATED_STACKS}; do
    stack_region="${entry%%/*}"
    stack_name="${entry#*/}"
    aws --region "${stack_region}" cloudformation describe-stack-events --stack-name "${stack_name}" --output json > "${ARTIFACT_DIR}/stack-events-${stack_name}.json"
  done
  set -o errexit
}

# Record a stack for event collection and for teardown by aws-deprovision-stacks.
function register_stack()
{
  local stack_region="$1" stack_name="$2"
  CREATED_STACKS="${CREATED_STACKS} ${stack_region}/${stack_name}"
  if [[ "${stack_region}" == "${REGION}" ]]; then
    echo "${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
  else
    echo "${stack_region}:${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
  fi
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

function is_dualstack() {
  if [[ "${IP_FAMILY:-}" == *"DualStack"* ]]; then
    return 0
  else
    return 1
  fi
}


vpc_tpl="/tmp/vpc_tpl.yaml"

cat > ${vpc_tpl} << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Created by aws-provision-vpc-disconnected

Parameters:
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.0.0/16
    Description: CIDR block for VPC.
    Type: String
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
  SubnetBitsIpv6:
    MinValue: 5
    MaxValue: 75
    Default: 64
    Description: "Size of each subnet to create within the availability zones. (Min: 5 = /122, Max: 75 = /53)"
    Type: Number
  EnableDualStack:
    Default: "no"
    AllowedValues:
    - "yes"
    - "no"
    Description: "Enable IPv6 DualStack support for VPC"
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
  DoDualStack: !Equals ["yes", !Ref EnableDualStack]

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
  VpcCidrBlockIpv6:
    Type: AWS::EC2::VPCCidrBlock
    Condition: DoDualStack
    Properties:
      VpcId: !Ref VPC
      AmazonProvidedIpv6CidrBlock: true
  PublicSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      Ipv6CidrBlock: !If [DoDualStack, !Select [ 0, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 6, !Ref SubnetBitsIpv6 ]], !Ref "AWS::NoValue"]
      AssignIpv6AddressOnCreation: !If [DoDualStack, true, false]
      AvailabilityZone: !Select
      - 0
      - Fn::GetAZs: !Ref "AWS::Region"
  PublicSubnet2:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      Ipv6CidrBlock: !If [DoDualStack, !Select [ 1, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 6, !Ref SubnetBitsIpv6 ]], !Ref "AWS::NoValue"]
      AssignIpv6AddressOnCreation: !If [DoDualStack, true, false]
      AvailabilityZone: !Select
      - 1
      - Fn::GetAZs: !Ref "AWS::Region"
  PublicSubnet3:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      Ipv6CidrBlock: !If [DoDualStack, !Select [ 2, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 6, !Ref SubnetBitsIpv6 ]], !Ref "AWS::NoValue"]
      AssignIpv6AddressOnCreation: !If [DoDualStack, true, false]
      AvailabilityZone: !Select
      - 2
      - Fn::GetAZs: !Ref "AWS::Region"
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
  PublicRouteIpv6:
    Type: "AWS::EC2::Route"
    Condition: DoDualStack
    DependsOn: GatewayToInternet
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationIpv6CidrBlock: ::/0
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
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      Ipv6CidrBlock: !If [DoDualStack, !Select [ 3, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 6, !Ref SubnetBitsIpv6 ]], !Ref "AWS::NoValue"]
      AssignIpv6AddressOnCreation: !If [DoDualStack, true, false]
      AvailabilityZone: !Select
      - 0
      - Fn::GetAZs: !Ref "AWS::Region"
  PrivateRouteTable:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PrivateSubnet
      RouteTableId: !Ref PrivateRouteTable
  PrivateSubnet2:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      Ipv6CidrBlock: !If [DoDualStack, !Select [ 4, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 6, !Ref SubnetBitsIpv6 ]], !Ref "AWS::NoValue"]
      AssignIpv6AddressOnCreation: !If [DoDualStack, true, false]
      AvailabilityZone: !Select
      - 1
      - Fn::GetAZs: !Ref "AWS::Region"
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
  PrivateSubnet3:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      Ipv6CidrBlock: !If [DoDualStack, !Select [ 5, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 6, !Ref SubnetBitsIpv6 ]], !Ref "AWS::NoValue"]
      AssignIpv6AddressOnCreation: !If [DoDualStack, true, false]
      AvailabilityZone: !Select
      - 2
      - Fn::GetAZs: !Ref "AWS::Region"
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
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .s3
      VpcId: !Ref VPC
  EndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: VPC Endpoint Security Group
      SecurityGroupIngress:
      - IpProtocol: -1
        CidrIp: !Ref VpcCidr
      VpcId: !Ref VPC
  ec2Endpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      PrivateDnsEnabled: true
      VpcEndpointType: Interface
      SecurityGroupIds:
      - !Ref EndpointSecurityGroup
      SubnetIds:
      - !Ref PrivateSubnet
      - !If [DoAz2, !Ref PrivateSubnet2, !Ref "AWS::NoValue"]
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .ec2
      VpcId: !Ref VPC
  efsEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      PrivateDnsEnabled: true
      VpcEndpointType: Interface
      SecurityGroupIds:
      - !Ref EndpointSecurityGroup
      SubnetIds:
      - !Ref PrivateSubnet
      - !If [DoAz2, !Ref PrivateSubnet2, !Ref "AWS::NoValue"]
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .elasticfilesystem
      VpcId: !Ref VPC
  elbEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      PrivateDnsEnabled: true
      VpcEndpointType: Interface
      SecurityGroupIds:
      - !Ref EndpointSecurityGroup
      SubnetIds:
      - !Ref PrivateSubnet
      - !If [DoAz2, !Ref PrivateSubnet2, !Ref "AWS::NoValue"]
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .elasticloadbalancing
      VpcId: !Ref VPC
  stsEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      PrivateDnsEnabled: true
      VpcEndpointType: Interface
      SecurityGroupIds:
      - !Ref EndpointSecurityGroup
      SubnetIds:
      - !Ref PrivateSubnet
      - !If [DoAz2, !Ref PrivateSubnet2, !Ref "AWS::NoValue"]
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .sts
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

Outputs:
  VpcId:
    Description: ID of the new VPC.
    Value: !Ref VPC
  Ipv4CidrBlock:
    Value: !GetAtt VPC.CidrBlock
  Ipv6CidrBlock:
    Value: !If [DoDualStack, !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks ], ""]
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
          !Join ["=", [
            !Select [0, "Fn::GetAZs": !Ref "AWS::Region"],
            !Ref PrivateRouteTable
          ]],
          !If [DoAz2,
               !Join ["=", [!Select [1, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable2]],
               !Ref "AWS::NoValue"
          ],
          !If [DoAz3,
               !Join ["=", [!Select [2, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable3]],
               !Ref "AWS::NoValue"
          ]
        ]
      ]
  AvailabilityZones:
    Value:
      !Join [
              ",",
              [
                !Select [0, "Fn::GetAZs": !Ref "AWS::Region"],
                !If [DoAz2, !Select [1, "Fn::GetAZs": !Ref "AWS::Region"], !Ref "AWS::NoValue"],
                !If [DoAz3, !Select [2, "Fn::GetAZs": !Ref "AWS::Region"], !Ref "AWS::NoValue"]
              ]
            ]
  SubnetsByAz1:
    Value:
      !Join [
              ",",
              [
                !Join [
                        ":",
                        [
                          !Select [0, "Fn::GetAZs": !Ref "AWS::Region"],
                          "public",
                          !Ref PublicSubnet
                        ]
                      ],
                !Join [
                        ":",
                        [
                          !Select [0, "Fn::GetAZs": !Ref "AWS::Region"],
                          "private",
                          !Ref PrivateSubnet
                        ]
                      ]
                ]
            ]
  SubnetsByAz2:
    Value:
      !If [
            DoAz2,
            !Join [
                    ",",
                    [
                      !Join [
                              ":",
                              [
                                !Select [1, "Fn::GetAZs": !Ref "AWS::Region"],
                                "public",
                                !Ref PublicSubnet2
                              ]
                            ],
                      !Join [
                              ":",
                              [
                                !Select [1, "Fn::GetAZs": !Ref "AWS::Region"],
                                "private",
                                !Ref PrivateSubnet2
                              ]
                            ]
                    ]
                  ],
            ""
          ]
  SubnetsByAz3:
    Value:
      !If [
            DoAz3,
            !Join [
                    ",",
                    [
                      !Join [
                              ":",
                              [
                                !Select [2, "Fn::GetAZs": !Ref "AWS::Region"],
                                "public",
                                !Ref PublicSubnet3
                              ]
                            ],
                      !Join [
                              ":",
                              [
                                !Select [2, "Fn::GetAZs": !Ref "AWS::Region"],
                                "private",
                                !Ref PrivateSubnet3
                              ]
                            ]
                    ]
                  ],
            ""
          ]
EOF





# The above cloudformation template's max zones account is 3
if [[ "${ZONES_COUNT}" -gt 3 ]]
then
  ZONES_COUNT=3
fi

STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-vpc"
register_stack "${REGION}" "${STACK_NAME}"

vpc_params="${ARTIFACT_DIR}/vpc_params.json"

# Prepare CloudFormation parameters
aws_add_param_to_json "AvailabilityZoneCount" "${ZONES_COUNT}" "${vpc_params}"
if is_dualstack; then
  aws_add_param_to_json "EnableDualStack" "yes" "${vpc_params}"
fi

aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat ${vpc_tpl})" \
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

#
# New VPC resources output vpc_info.json
# {
#   "vpc_id": "vpc-1",
#   "vpc_ipv4_cidr": "10.0.0.0/16",
#   "vpc_ipv6_cidr": "2600:1f13:fc9:fd00::/56",
#   "subnets": [
#     {
#       "az": "us-east-1a",
#       "ids": [
#         {
#           "private": "subnet-us-east-1a-priv-1",
#           "public": "subnet-us-east-1a-pub-1"
#         }
#       ]
#     },
#     {
#       "az": "us-east-1b",
#       "ids": [
#         {
#           "private": "subnet-us-east-1b-priv-1",
#           "public": "subnet-us-east-1b-pub-1"
#         }
#       ]
#     }
#   ]
# }

vpc_info_json=${SHARED_DIR}/vpc_info.json
echo '{}' > ${vpc_info_json}

# vpc_id
cat <<< "$(jq --arg v $VpcId '.vpc_id = $v' ${vpc_info_json})" > ${vpc_info_json}

# IPv4 CIDR — always written so the from-disk isolation step can scope its
# firewall exemption to the actual VPC CIDR rather than falling back to /8.
VpcIpv4CidrBlock=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="Ipv4CidrBlock") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
cat <<< "$(jq --arg v $VpcIpv4CidrBlock '.vpc_ipv4_cidr = $v' ${vpc_info_json})" > ${vpc_info_json}

# IPv6 CIDR — only present for dual-stack runs
if is_dualstack; then
  VpcIpv6CidrBlock=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="Ipv6CidrBlock") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
  cat <<< "$(jq --arg v $VpcIpv6CidrBlock '.vpc_ipv6_cidr = $v' ${vpc_info_json})" > ${vpc_info_json}
fi

# Subnets by AZ
subnets_by_az_1=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="SubnetsByAz1") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
subnets_by_az_2=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="SubnetsByAz2") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
subnets_by_az_3=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="SubnetsByAz3") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")

echo "subnets_by_az_1: $subnets_by_az_1"
echo "subnets_by_az_2: $subnets_by_az_2"
echo "subnets_by_az_3: $subnets_by_az_3"

az_idx=0
for subnets_by_az in $subnets_by_az_1 $subnets_by_az_2 $subnets_by_az_3;
do
  t_subnets=$(mktemp)
  echo '{}' > $t_subnets
  for subnet_by_az in $(echo $subnets_by_az | sed 's/,/ /g' );
  do
    # us-east-1a:public:subnet-0f6272026e3b61e19,us-east-1a:private:subnet-05490ab3e6019f706
    az=$(echo ${subnet_by_az} | cut -d":" -f1)
    attr=$(echo ${subnet_by_az} | cut -d":" -f2)
    id_idx=0
    for subnet_id in $(echo ${subnet_by_az} | cut -d":" -f3 | sed 's/+/ /g' );
    do
      cat <<< "$(jq --arg az $az '.az = $az' ${t_subnets})" > ${t_subnets}
      cat <<< "$(jq --arg subnet_id $subnet_id --argjson id_idx $id_idx --arg attr $attr '.ids[$id_idx][$attr] = $subnet_id' ${t_subnets})" > ${t_subnets}
      id_idx=$((id_idx+1))
    done
  done
  cat <<< "$(jq --argjson t "$(jq -c '.' $t_subnets)" --argjson az_idx $az_idx '.subnets[$az_idx] += $t' ${vpc_info_json})" > ${vpc_info_json}
  az_idx=$((az_idx+1))
done
cp $vpc_info_json $ARTIFACT_DIR/
cat $vpc_info_json | jq

# ---------------------------------------------------------------------------
# Cross-region EC2 API resolution
#
# machine-api validates the cluster's region with ec2:DescribeRegions against
# us-east-1, because an opt-in region cannot be queried through its own
# endpoint until it is known to be enabled. In a disconnected VPC that call has
# nowhere to go: the local interface endpoint only serves ${REGION}, and EC2 is
# not one of the services AWS has enabled for cross-region PrivateLink, so a
# ServiceRegion endpoint is not available either.
#
# Instead stand up a small VPC in the peer region holding an ordinary ec2
# interface endpoint, peer it with the disconnected VPC, and publish a private
# hosted zone so ec2.<peer-region>.amazonaws.com resolves to that endpoint's
# addresses from inside the cluster. The endpoint serves the real AWS
# certificate for that name, so TLS and SigV4 both validate unchanged, and no
# egress to the internet is introduced.
# ---------------------------------------------------------------------------

if [[ -n "${EC2_ENDPOINT_PEER_REGION}" && "${EC2_ENDPOINT_PEER_REGION}" != "${REGION}" ]]; then
  PEER_REGION="${EC2_ENDPOINT_PEER_REGION}"
  PEER_VPC_CIDR="${EC2_ENDPOINT_PEER_VPC_CIDR}"
  PEER_SERVICE_NAME="ec2.${PEER_REGION}.amazonaws.com"

  echo "Provisioning a peer VPC in ${PEER_REGION} so ${PEER_SERVICE_NAME} resolves inside the disconnected VPC"

  # Only some AZs offer the ec2 interface endpoint, and which ones differ per
  # account, so pick from the service's own list rather than from GetAZs.
  peer_azs=$(aws --region "${PEER_REGION}" ec2 describe-vpc-endpoint-services \
    --service-names "com.amazonaws.${PEER_REGION}.ec2" \
    --query 'ServiceDetails[0].AvailabilityZones' --output text)
  read -r peer_az1 peer_az2 _ <<< "${peer_azs}" || true
  if [[ -z "${peer_az1:-}" || -z "${peer_az2:-}" ]]; then
    echo "Expected at least two availability zones offering com.amazonaws.${PEER_REGION}.ec2, got: ${peer_azs}"
    exit 1
  fi
  echo "Peer endpoint availability zones: ${peer_az1} ${peer_az2}"

  peer_tpl="/tmp/ec2_peer_vpc_tpl.yaml"
  cat > ${peer_tpl} << 'EOF'
AWSTemplateFormatVersion: 2010-09-09
Description: Created by aws-provision-vpc-disconnected (cross-region EC2 endpoint)

Parameters:
  VpcCidr:
    Type: String
    Description: CIDR block for the peer VPC.
  AvailabilityZone1:
    Type: String
  AvailabilityZone2:
    Type: String
  PeerVpcId:
    Type: String
    Description: ID of the disconnected VPC to peer with.
  PeerVpcCidr:
    Type: String
    Description: CIDR block of the disconnected VPC.
  PeerRegion:
    Type: String
    Description: Region of the disconnected VPC.

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
  Subnet1:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 2, 8]]
      AvailabilityZone: !Ref AvailabilityZone1
  Subnet2:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 2, 8]]
      AvailabilityZone: !Ref AvailabilityZone2
  RouteTable:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  Subnet1RouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref Subnet1
      RouteTableId: !Ref RouteTable
  Subnet2RouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref Subnet2
      RouteTableId: !Ref RouteTable
  EndpointSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Cross-region EC2 endpoint security group
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 443
        ToPort: 443
        CidrIp: !Ref PeerVpcCidr
      VpcId: !Ref VPC
  ec2Endpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      PrivateDnsEnabled: false
      VpcEndpointType: Interface
      SecurityGroupIds:
      - !Ref EndpointSecurityGroup
      SubnetIds:
      - !Ref Subnet1
      - !Ref Subnet2
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .ec2
      VpcId: !Ref VPC
  VpcPeeringConnection:
    Type: AWS::EC2::VPCPeeringConnection
    Properties:
      VpcId: !Ref VPC
      PeerVpcId: !Ref PeerVpcId
      PeerRegion: !Ref PeerRegion
      Tags:
      - Key: Name
        Value: !Join [ "-", [ !Ref "AWS::StackName", "pcx" ] ]

Outputs:
  VpcId:
    Description: ID of the peer VPC.
    Value: !Ref VPC
  RouteTableId:
    Description: Route table serving the endpoint subnets.
    Value: !Ref RouteTable
  VpcPeeringConnectionId:
    Description: Peering connection to the disconnected VPC.
    Value: !Ref VpcPeeringConnection
  EndpointNetworkInterfaceIds:
    Description: ENIs backing the cross-region ec2 interface endpoint.
    Value: !Join [ ",", !GetAtt ec2Endpoint.NetworkInterfaceIds ]
EOF

  PEER_STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-ec2-peer"
  register_stack "${PEER_REGION}" "${PEER_STACK_NAME}"

  peer_params="${ARTIFACT_DIR}/ec2_peer_vpc_params.json"
  aws_add_param_to_json "VpcCidr" "${PEER_VPC_CIDR}" "${peer_params}"
  aws_add_param_to_json "AvailabilityZone1" "${peer_az1}" "${peer_params}"
  aws_add_param_to_json "AvailabilityZone2" "${peer_az2}" "${peer_params}"
  aws_add_param_to_json "PeerVpcId" "${VpcId}" "${peer_params}"
  aws_add_param_to_json "PeerVpcCidr" "${VpcIpv4CidrBlock}" "${peer_params}"
  aws_add_param_to_json "PeerRegion" "${REGION}" "${peer_params}"

  aws --region "${PEER_REGION}" cloudformation create-stack \
    --stack-name "${PEER_STACK_NAME}" \
    --template-body "$(cat ${peer_tpl})" \
    --tags "${TAGS}" \
    --parameters file://${peer_params} &
  wait "$!"
  echo "Created peer stack"

  aws --region "${PEER_REGION}" cloudformation wait stack-create-complete --stack-name "${PEER_STACK_NAME}" &
  wait "$!"
  echo "Waited for peer stack"

  peer_stack_output="${SHARED_DIR}/ec2_peer_vpc_stack_output"
  aws --region "${PEER_REGION}" cloudformation describe-stacks --stack-name "${PEER_STACK_NAME}" > "${peer_stack_output}"
  cp "${peer_stack_output}" "${ARTIFACT_DIR}/"

  function peer_stack_output_value() {
    jq -r --arg k "$1" '.Stacks[].Outputs[] | select(.OutputKey==$k) | .OutputValue' "${peer_stack_output}"
  }

  PeerVpcId=$(peer_stack_output_value "VpcId")
  PeerRouteTableId=$(peer_stack_output_value "RouteTableId")
  PcxId=$(peer_stack_output_value "VpcPeeringConnectionId")
  EndpointEniIds=$(peer_stack_output_value "EndpointNetworkInterfaceIds" | tr ',' ' ')
  echo "PeerVpcId: ${PeerVpcId}"
  echo "VpcPeeringConnectionId: ${PcxId}"

  # Same-account peering requests are normally auto-accepted, but that is not
  # guaranteed across regions. Accept from the accepter's region if needed, and
  # only lay down routes once the connection is actually active.
  pcx_state=""
  for _ in $(seq 1 40); do
    pcx_state=$(aws --region "${PEER_REGION}" ec2 describe-vpc-peering-connections \
      --vpc-peering-connection-ids "${PcxId}" \
      --query 'VpcPeeringConnections[0].Status.Code' --output text)
    [[ "${pcx_state}" == "active" ]] && break
    if [[ "${pcx_state}" == "pending-acceptance" ]]; then
      echo "Accepting peering connection ${PcxId} in ${REGION}"
      aws --region "${REGION}" ec2 accept-vpc-peering-connection \
        --vpc-peering-connection-id "${PcxId}" > /dev/null || true
    fi
    sleep 15
  done
  if [[ "${pcx_state}" != "active" ]]; then
    echo "Peering connection ${PcxId} did not become active, last state: ${pcx_state}"
    exit 1
  fi
  echo "Peering connection ${PcxId} is active"

  # The routes go into their own stacks rather than being created with
  # ec2 create-route. Nothing is then created out of band, and because
  # aws-deprovision-stacks deletes in reverse order the routes are removed
  # before the peering connection they point at.
  function create_routes_stack() {
    local stack_region="$1" stack_name="$2" destination_cidr="$3"
    shift 3
    local route_table_ids=("$@")
    local tpl rtb_id idx=0
    tpl=$(mktemp)
    {
      echo "AWSTemplateFormatVersion: 2010-09-09"
      echo "Description: Created by aws-provision-vpc-disconnected (peering routes)"
      echo ""
      echo "Resources:"
      for rtb_id in "${route_table_ids[@]}"; do
        idx=$((idx+1))
        echo "  Route${idx}:"
        echo "    Type: AWS::EC2::Route"
        echo "    Properties:"
        echo "      RouteTableId: ${rtb_id}"
        echo "      DestinationCidrBlock: ${destination_cidr}"
        echo "      VpcPeeringConnectionId: ${PcxId}"
      done
    } > "${tpl}"
    cp "${tpl}" "${ARTIFACT_DIR}/${stack_name}-template.yaml"

    register_stack "${stack_region}" "${stack_name}"
    aws --region "${stack_region}" cloudformation create-stack \
      --stack-name "${stack_name}" \
      --template-body "$(cat ${tpl})" \
      --tags "${TAGS}" &
    wait "$!"
    aws --region "${stack_region}" cloudformation wait stack-create-complete --stack-name "${stack_name}" &
    wait "$!"
    echo "Routed ${destination_cidr} via ${PcxId} in ${stack_region}: ${route_table_ids[*]}"
  }

  # Return path in the peer region.
  create_routes_stack "${PEER_REGION}" "${NAMESPACE}-${UNIQUE_HASH}-ec2-peer-routes" \
    "${VpcIpv4CidrBlock}" "${PeerRouteTableId}"

  # Forward path from every subnet of the disconnected VPC. The public route
  # table is included so the bastion resolves the name the same way the nodes
  # do; the private hosted zone below applies to the whole VPC.
  local_route_table_ids=("${PublicRouteTableId}")
  while read -r rtb_id; do
    if [[ -n "${rtb_id}" ]]; then
      local_route_table_ids+=("${rtb_id}")
    fi
  done < <(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateRouteTableIds") | .OutputValue' "${SHARED_DIR}/vpc_stack_output" | tr ',' '\n' | cut -d= -f2)

  create_routes_stack "${REGION}" "${NAMESPACE}-${UNIQUE_HASH}-ec2-peer-local-routes" \
    "${PEER_VPC_CIDR}" "${local_route_table_ids[@]}"

  # Private DNS is disabled on the peer endpoint, so publish the name ourselves
  # against the endpoint's addresses.
  endpoint_ips=$(aws --region "${PEER_REGION}" ec2 describe-network-interfaces \
    --network-interface-ids ${EndpointEniIds} \
    --query 'NetworkInterfaces[].PrivateIpAddress' --output text)
  if [[ -z "${endpoint_ips}" ]]; then
    echo "Could not determine the addresses of the ${PEER_SERVICE_NAME} endpoint"
    exit 1
  fi
  echo "Endpoint addresses for ${PEER_SERVICE_NAME}: ${endpoint_ips}"

  phz_tpl="/tmp/ec2_peer_phz_tpl.yaml"
  {
    echo "AWSTemplateFormatVersion: 2010-09-09"
    echo "Description: Created by aws-provision-vpc-disconnected (private zone for ${PEER_SERVICE_NAME})"
    echo ""
    echo "Resources:"
    echo "  HostedZone:"
    echo "    Type: AWS::Route53::HostedZone"
    echo "    Properties:"
    echo "      Name: ${PEER_SERVICE_NAME}."
    echo "      HostedZoneConfig:"
    echo "        Comment: Resolves ${PEER_SERVICE_NAME} to a peered interface endpoint"
    echo "      VPCs:"
    echo "      - VPCId: ${VpcId}"
    echo "        VPCRegion: ${REGION}"
    echo "  Record:"
    echo "    Type: AWS::Route53::RecordSet"
    echo "    Properties:"
    echo "      HostedZoneId: !Ref HostedZone"
    echo "      Name: ${PEER_SERVICE_NAME}."
    echo "      Type: A"
    echo "      TTL: 60"
    echo "      ResourceRecords:"
    for endpoint_ip in ${endpoint_ips}; do
      echo "      - ${endpoint_ip}"
    done
    echo ""
    echo "Outputs:"
    echo "  HostedZoneId:"
    echo "    Value: !Ref HostedZone"
  } > ${phz_tpl}
  cp ${phz_tpl} "${ARTIFACT_DIR}/"

  PHZ_STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-ec2-peer-phz"
  register_stack "${REGION}" "${PHZ_STACK_NAME}"

  aws --region "${REGION}" cloudformation create-stack \
    --stack-name "${PHZ_STACK_NAME}" \
    --template-body "$(cat ${phz_tpl})" \
    --tags "${TAGS}" &
  wait "$!"
  echo "Created private hosted zone stack"

  aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${PHZ_STACK_NAME}" &
  wait "$!"
  echo "${PEER_SERVICE_NAME} now resolves to ${endpoint_ips} inside ${VpcId}"
fi