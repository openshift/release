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
Description: Created by aws-provision-vpc-shared-dualstack

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
  SubnetBitsIpv6:
    MinValue: 5
    MaxValue: 75
    Default: 64
    Description: "Size of each subnet to create within the availability zones. (Min: 5 = /122, Max: 75 = /53)"
    Type: Number
  DhcpOptionSet:
    Default: "no"
    AllowedValues:
    - "yes"
    - "no"
    Description: "Create a dhcpOptionSet with a custom DNS name"
    Type: String
  Ipv6OnlyPrivateSubnets:
    Default: "no"
    AllowedValues:
    - "yes"
    - "no"
    Description: "Create ipv6-only subnets in the dualstack vpc"
    Type: String
  AllowedAvailabilityZoneList:
    ConstraintDescription: "Select AZs from this list, e.g. 'us-east-2c,us-east-2a'"
    Type: CommaDelimitedList
    Default: ""

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
  DoIpv6OnlyPrivateSubnets: !Equals ["yes", !Ref Ipv6OnlyPrivateSubnets]
  DoIpv4NatAZ3: !And [!Not [Condition: DoIpv6OnlyPrivateSubnets], Condition: DoAz3]
  DoIpv4NatAZ2: !And [!Not [Condition: DoIpv6OnlyPrivateSubnets], Condition: DoAz2]
  DoIpv4NatAZ1: !Not [Condition: DoIpv6OnlyPrivateSubnets]
  AzRestriction: !Not [!Equals [!Join ['', !Ref AllowedAvailabilityZoneList], '']]

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
    Properties:
      VpcId: !Ref VPC
      AmazonProvidedIpv6CidrBlock: true
  PublicSubnet:
    DependsOn: VpcCidrBlockIpv6
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
      Ipv6CidrBlock: !Select [ 0, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 8, !Ref SubnetBitsIpv6 ]]
      AssignIpv6AddressOnCreation: true
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet2:
    DependsOn: VpcCidrBlockIpv6
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
      Ipv6CidrBlock: !Select [ 1, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 8, !Ref SubnetBitsIpv6 ]]
      AssignIpv6AddressOnCreation: true
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [1, !Ref AllowedAvailabilityZoneList ],
              !Select [1, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet3:
    DependsOn: VpcCidrBlockIpv6
    Type: "AWS::EC2::Subnet"
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
      Ipv6CidrBlock: !Select [ 2, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 8, !Ref SubnetBitsIpv6 ]]
      AssignIpv6AddressOnCreation: true
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
  PublicRouteIpv6:
    Type: "AWS::EC2::Route"
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
  EOIG:
    DependsOn: VpcCidrBlockIpv6
    Type: AWS::EC2::EgressOnlyInternetGateway
    Properties:
      VpcId: !Ref VPC
  PrivateSubnet:
    DependsOn: VpcCidrBlockIpv6
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !If [ DoIpv6OnlyPrivateSubnets, !Ref "AWS::NoValue", !Select [3, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]] ]
      EnableDns64: !If [ DoIpv6OnlyPrivateSubnets, true, false ]
      Ipv6Native: !If [ DoIpv6OnlyPrivateSubnets, true, false ]
      Ipv6CidrBlock: !Select [ 3, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 8, !Ref SubnetBitsIpv6 ]]
      AssignIpv6AddressOnCreation: true
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
    Condition: DoIpv4NatAZ1
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP
        - AllocationId
      SubnetId: !Ref PublicSubnet
  EIP:
    Type: "AWS::EC2::EIP"
    Condition: DoIpv4NatAZ1
    Properties:
      Domain: vpc
  Route:
    Type: "AWS::EC2::Route"
    Condition: DoIpv4NatAZ1
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT
  RouteIpv6:
    DependsOn:
    - EOIG
    Type: "AWS::EC2::Route"
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable
      DestinationIpv6CidrBlock: ::/0
      EgressOnlyInternetGatewayId:
        Ref: EOIG
  PrivateSubnet2:
    DependsOn: VpcCidrBlockIpv6
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !If [ DoIpv6OnlyPrivateSubnets, !Ref "AWS::NoValue", !Select [4, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]] ]
      EnableDns64: !If [ DoIpv6OnlyPrivateSubnets, true, false ]
      Ipv6Native: !If [ DoIpv6OnlyPrivateSubnets, true, false ]
      Ipv6CidrBlock: !Select [ 4, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 8, !Ref SubnetBitsIpv6 ]]
      AssignIpv6AddressOnCreation: true
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
    Condition: DoIpv4NatAZ2
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP2
        - AllocationId
      SubnetId: !Ref PublicSubnet2
  EIP2:
    Type: "AWS::EC2::EIP"
    Condition: DoIpv4NatAZ2
    Properties:
      Domain: vpc
  Route2:
    Type: "AWS::EC2::Route"
    Condition: DoIpv4NatAZ2
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable2
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT2
  Route2Ipv6:
    DependsOn:
    - EOIG
    Type: "AWS::EC2::Route"
    Condition: DoAz2
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable2
      DestinationIpv6CidrBlock: ::/0
      EgressOnlyInternetGatewayId:
        Ref: EOIG
  PrivateSubnet3:
    DependsOn: VpcCidrBlockIpv6
    Type: "AWS::EC2::Subnet"
    Condition: DoAz3
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !If [ DoIpv6OnlyPrivateSubnets, !Ref "AWS::NoValue", !Select [5, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]] ]
      EnableDns64: !If [ DoIpv6OnlyPrivateSubnets, true, false ]
      Ipv6Native: !If [ DoIpv6OnlyPrivateSubnets, true, false ]
      Ipv6CidrBlock: !Select [ 5, !Cidr [ !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks], 8, !Ref SubnetBitsIpv6 ]]
      AssignIpv6AddressOnCreation: true
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
    Condition: DoIpv4NatAZ3
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP3
        - AllocationId
      SubnetId: !Ref PublicSubnet3
  EIP3:
    Type: "AWS::EC2::EIP"
    Condition: DoIpv4NatAZ3
    Properties:
      Domain: vpc
  Route3:
    Type: "AWS::EC2::Route"
    Condition: DoIpv4NatAZ3
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable3
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT3
  Route3Ipv6:
    DependsOn:
    - EOIG
    Type: "AWS::EC2::Route"
    Condition: DoAz3
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable3
      DestinationIpv6CidrBlock: ::/0
      EgressOnlyInternetGatewayId:
        Ref: EOIG
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
    Value: !Select [ 0, !GetAtt VPC.Ipv6CidrBlocks ]
  PublicSubnetIds:
    Description: Subnet IDs of the public subnets.
    Value:
      !Join [ 
              ",",
              [ !Ref PublicSubnet, !If [DoAz2, !Ref PublicSubnet2, !Ref "AWS::NoValue"], !If [DoAz3, !Ref PublicSubnet3, !Ref "AWS::NoValue"] ]
            ]
  PrivateSubnetIds:
    Description: Subnet IDs of the private subnets.
    Value:
      !Join [ 
              ",",
              [ !Ref PrivateSubnet, !If [DoAz2, !Ref PrivateSubnet2, !Ref "AWS::NoValue"], !If [DoAz3, !Ref PrivateSubnet3, !Ref "AWS::NoValue"] ]
            ]
  AvailabilityZones:
    Value:
      !Join [ 
              ",",
              [
                !Select [0, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                !If [DoAz2, !Select [1, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]], !Ref "AWS::NoValue"],
                !If [DoAz3, !Select [2, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]], !Ref "AWS::NoValue"]
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
                          !Select [0, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                          "public",
                          !Join ["+", [ !Ref PublicSubnet ] ]
                        ]
                      ],
                !Join [
                        ":",
                        [
                          !Select [0, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                          "private",
                          !Join [ "+", [ !Ref PrivateSubnet ] ]
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
                                !Select [1, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                                "public",
                                !Join [ "+", [ !Ref PublicSubnet2 ] ]
                              ]
                            ],
                      !Join [
                              ":",
                              [
                                !Select [1, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                                "private",
                                !Join [ "+", [ !Ref PrivateSubnet2 ] ]
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
                                !Select [2, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                                "public",
                                !Join [ "+", [ !Ref PublicSubnet3 ] ]
                              ]
                            ],
                      !Join [
                              ":",
                              [
                                !Select [2, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                                "private",
                                !Join [ "+", [ !Ref PrivateSubnet3 ] ]
                              ]
                            ]
                    ]
                  ],
            ""
          ]
EOF
# In the above template, note that:
# PublicRoute.DestinationIpv6CidrBlock (::/0->InternetGateway) make the instances in public subnets have the capacity
# of outgoing traffic to internet over IPv6, or else, they can't go to internet even if they have ipv6 address.
# If want the instances in private subnets also have the capacity of outgoing traffic to internet over IPv6, have to
# create AWS::EC2::EgressOnlyInternetGateway, then add route rules (::/0->EgressOnlyInternetGateway) in each private
# subnet's Route-N. EgressOnlyInternetGateway is only for ipv6, which is similar to NAT only for ipv6. We can utilize
# it to create a disconnected ipv6 network environment.
# IPv6-based service running on the instance in public subnets can be accessed, but if the instance is running in a
# private subnet, the service can not be available.

MAX_ZONES_COUNT=$(aws --region "${REGION}" ec2 describe-availability-zones --filter Name=state,Values=available Name=zone-type,Values=availability-zone | jq '.AvailabilityZones | length')
if (( ZONES_COUNT > MAX_ZONES_COUNT )); then
  ZONES_COUNT=$MAX_ZONES_COUNT
fi

# The above cloudformation template's max zones account is 3
if [[ "${ZONES_COUNT}" -gt 3 ]]; then
  ZONES_COUNT=3
fi

STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-vpc"
echo ${STACK_NAME} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"

vpc_params="${ARTIFACT_DIR}/vpc_params.json"
aws_add_param_to_json "AvailabilityZoneCount" ${ZONES_COUNT} "$vpc_params"

if [[ -n "${VPC_CIDR}" ]]; then
     aws_add_param_to_json "VpcCidr" ${VPC_CIDR} "$vpc_params"
fi

if [[ ${ZONES_LIST} != "" ]]; then
  zones_list_count=$(echo "$ZONES_LIST" | awk -F',' '{ print NF }')
  if [[ "${zones_list_count}" != "${ZONES_COUNT}" ]]; then
    echo "ERROR: ${zones_list_count} zones in the list [${ZONES_LIST}], the zone count in the list should be the same as ZONES_COUNT: ${ZONES_COUNT}, exit now"
    exit 1
  fi
  aws_add_param_to_json "AllowedAvailabilityZoneList" "${ZONES_LIST}" "$vpc_params"
fi

aws_add_param_to_json "Ipv6OnlyPrivateSubnets" "${VPC_IPv6_ONLY_PRIVATE_SUBNETS:-no}" "$vpc_params"

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

# save vpc stack output
aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > "${SHARED_DIR}/vpc_stack_output"

# save vpc id
# e.g. 
#   vpc-01739b6510a152d44
VpcId=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="VpcId") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
echo "VpcId: ${VpcId}"

# New VPC resources output vpc_info.json
# {
#   "vpc_id": "vpc-1",
#   "subnets": [
#     {
#       "az": "us-east-1a",
#       "ids": [
#         {
#           "private": "subnet-us-east-1a-priv-1",
#           "public": "subnet-us-east-1a-pub-1"
#         },
#         {
#           "private": "subnet-us-east-1a-priv-2",
#           "public": "subnet-us-east-1a-pub-2"
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
#     },
#     {
#       "az": "us-east-1c",
#       "ids": [
#         {
#           "private": "subnet-us-east-1c-priv-1",
#           "public": "subnet-us-east-1c-pub-1"
#         }
#       ]
#     }
#   ]
# }

vpc_info_json=${SHARED_DIR}/vpc_info.json
echo '{}' > ${vpc_info_json}

# vpc_id
cat <<< "$(jq --arg v $VpcId '.vpc_id = $v' ${vpc_info_json})" > ${vpc_info_json}

VpcIpv4CidrBlock=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="Ipv4CidrBlock") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
VpcIpv6CidrBlock=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="Ipv6CidrBlock") | .OutputValue' "${SHARED_DIR}/vpc_stack_output")
cat <<< "$(jq --arg v $VpcIpv4CidrBlock '.vpc_ipv4_cidr = $v' ${vpc_info_json})" > ${vpc_info_json}
cat <<< "$(jq --arg v $VpcIpv6CidrBlock '.vpc_ipv6_cidr = $v' ${vpc_info_json})" > ${vpc_info_json}

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
    # us-east-1a:public:subnet-0f6272026e3b61e19+subnet-03c1988dda6f2cc64,us-east-1a:private:subnet-05490ab3e6019f706+subnet-05128388f4be23f56
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
