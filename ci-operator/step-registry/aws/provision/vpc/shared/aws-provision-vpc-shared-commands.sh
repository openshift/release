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
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  CLUSTER_CREATOR_USER_ARN=$(aws sts get-caller-identity | jq -r '.Arn')
  CLUSTER_CREATOR_AWS_ACCOUNT_NO=$(echo $CLUSTER_CREATOR_USER_ARN | awk -F ":" '{print $5}')
  echo "Using shared AWS account, cluster creator account: ${CLUSTER_CREATOR_AWS_ACCOUNT_NO:0:6}***"
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
else
  echo "Using regular AWS account."
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
Description: Created by aws-provision-vpc-shared

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
  OnlyPublicSubnets:
    Default: "no"
    AllowedValues:
    - "yes"
    - "no"
    Description: "Only create public subnets"
    Type: String
  AllowedAvailabilityZoneList:
    ConstraintDescription: "Select AZs from this list, e.g. 'us-east-2c,us-east-2a'"
    Type: CommaDelimitedList
    Default: ""
  ResourceSharePrincipals:
    ConstraintDescription: ResourceSharePrincipals
    Default: ""
    Description: "ResourceSharePrincipals"
    Type: String
  AdditionalSubnetsCount:
    Description: "If yes, an additional pub/priv subnets will be created in the same AZ."
    MinValue: 0
    MaxValue: 1
    Default: 0
    Type: Number

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
  DoOnlyPublicSubnets: !Equals ["yes", !Ref OnlyPublicSubnets]
  DoAz1PrivateSubnet: !Not [Condition: DoOnlyPublicSubnets]
  DoAz2PrivateSubnet: !And [ !Not [Condition: DoOnlyPublicSubnets], Condition: DoAz2 ]
  DoAz3PrivateSubnet: !And [ !Not [Condition: DoOnlyPublicSubnets], Condition: DoAz3 ]
  AzRestriction: !Not [ !Equals [!Join ['', !Ref AllowedAvailabilityZoneList], ''] ]
  ShareSubnets: !Not [ !Equals ['', !Ref ResourceSharePrincipals] ]
  DoAdditionalAz: !Equals [1, !Ref AdditionalSubnetsCount]
  DoAz1aPrivateSubnet: !And [ Condition: DoAz1PrivateSubnet, Condition: DoAdditionalAz ]

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
      MapPublicIpOnLaunch:
        !If [
              "DoOnlyPublicSubnets",
              "true",
              "false"
            ]
      VpcId: !Ref VPC
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PublicSubnet1a:
    Type: "AWS::EC2::Subnet"
    Condition: DoAdditionalAz
    Properties:
      MapPublicIpOnLaunch:
        !If [
              "DoOnlyPublicSubnets",
              "true",
              "false"
            ]
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
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
      MapPublicIpOnLaunch:
        !If [
              "DoOnlyPublicSubnets",
              "true",
              "false"
            ]
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
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
      MapPublicIpOnLaunch:
        !If [
              "DoOnlyPublicSubnets",
              "true",
              "false"
            ]
      VpcId: !Ref VPC
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
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
  PublicSubnetRouteTableAssociation1a:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAdditionalAz
    Properties:
      SubnetId: !Ref PublicSubnet1a
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
    Condition: DoAz1PrivateSubnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [4, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable:
    Condition: DoAz1PrivateSubnet
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz1PrivateSubnet
    Properties:
      SubnetId: !Ref PrivateSubnet
      RouteTableId: !Ref PrivateRouteTable
  NAT:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz1PrivateSubnet
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP
        - AllocationId
      SubnetId: !Ref PublicSubnet
  EIP:
    Type: "AWS::EC2::EIP"
    Condition: DoAz1PrivateSubnet
    Properties:
      Domain: vpc
  Route:
    Type: "AWS::EC2::Route"
    Condition: DoAz1PrivateSubnet
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT
  PrivateSubnet1a:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz1aPrivateSubnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [5, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [0, !Ref AllowedAvailabilityZoneList ],
              !Select [0, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable1a:
    Condition: DoAz1aPrivateSubnet
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation1a:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz1aPrivateSubnet
    Properties:
      SubnetId: !Ref PrivateSubnet1a
      RouteTableId: !Ref PrivateRouteTable1a
  NAT1a:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz1aPrivateSubnet
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP1a
        - AllocationId
      SubnetId: !Ref PublicSubnet1a
  EIP1a:
    Type: "AWS::EC2::EIP"
    Condition: DoAz1aPrivateSubnet
    Properties:
      Domain: vpc
  Route1a:
    Type: "AWS::EC2::Route"
    Condition: DoAz1aPrivateSubnet
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable1a
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT1a
  PrivateSubnet2:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz2PrivateSubnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [6, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [1, !Ref AllowedAvailabilityZoneList ],
              !Select [1, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable2:
    Type: "AWS::EC2::RouteTable"
    Condition: DoAz2PrivateSubnet
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation2:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz2PrivateSubnet
    Properties:
      SubnetId: !Ref PrivateSubnet2
      RouteTableId: !Ref PrivateRouteTable2
  NAT2:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz2PrivateSubnet
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP2
        - AllocationId
      SubnetId: !Ref PublicSubnet2
  EIP2:
    Type: "AWS::EC2::EIP"
    Condition: DoAz2PrivateSubnet
    Properties:
      Domain: vpc
  Route2:
    Type: "AWS::EC2::Route"
    Condition: DoAz2PrivateSubnet
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable2
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT2
  PrivateSubnet3:
    Type: "AWS::EC2::Subnet"
    Condition: DoAz3PrivateSubnet
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [7, !Cidr [!Ref VpcCidr, 8, !Ref SubnetBits]]
      AvailabilityZone:
        !If [
              "AzRestriction",
              !Select [2, !Ref AllowedAvailabilityZoneList ],
              !Select [2, Fn::GetAZs: !Ref "AWS::Region"]
            ]
  PrivateRouteTable3:
    Type: "AWS::EC2::RouteTable"
    Condition: DoAz3PrivateSubnet
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociation3:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Condition: DoAz3PrivateSubnet
    Properties:
      SubnetId: !Ref PrivateSubnet3
      RouteTableId: !Ref PrivateRouteTable3
  NAT3:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Condition: DoAz3PrivateSubnet
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIP3
        - AllocationId
      SubnetId: !Ref PublicSubnet3
  EIP3:
    Type: "AWS::EC2::EIP"
    Condition: DoAz3PrivateSubnet
    Properties:
      Domain: vpc
  Route3:
    Type: "AWS::EC2::Route"
    Condition: DoAz3PrivateSubnet
    Properties:
      RouteTableId:
        Ref: PrivateRouteTable3
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NAT3
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
      - !If [DoAz1PrivateSubnet, !Ref PrivateRouteTable, !Ref "AWS::NoValue"]
      - !If [DoAz2PrivateSubnet, !Ref PrivateRouteTable2, !Ref "AWS::NoValue"]
      - !If [DoAz3PrivateSubnet, !Ref PrivateRouteTable3, !Ref "AWS::NoValue"]
      - !If [DoAz1aPrivateSubnet, !Ref PrivateRouteTable1a, !Ref "AWS::NoValue"]
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
        [!If [DoAz1PrivateSubnet, !Ref PrivateSubnet, !Ref "AWS::NoValue"], !If [DoAz2PrivateSubnet, !Ref PrivateSubnet2, !Ref "AWS::NoValue"], !If [DoAz3PrivateSubnet, !Ref PrivateSubnet3, !Ref "AWS::NoValue"]]
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
          !If [DoAz1PrivateSubnet,
                !If [
                  "AzRestriction",
                  !Join ["=", [!Select [0, !Ref AllowedAvailabilityZoneList], !Ref PrivateRouteTable]],
                  !Join ["=", [!Select [0, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable]]
                ],
               !Ref "AWS::NoValue"
          ],
          !If [DoAz2PrivateSubnet,
                !If [
                  "AzRestriction",
                  !Join ["=", [!Select [1, !Ref AllowedAvailabilityZoneList], !Ref PrivateRouteTable2]],
                  !Join ["=", [!Select [1, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable2]]
                ],
               !Ref "AWS::NoValue"
          ],
          !If [DoAz3PrivateSubnet,
               !If [
                  "AzRestriction",
                  !Join ["=", [!Select [2, !Ref AllowedAvailabilityZoneList], !Ref PrivateRouteTable3]],
                  !Join ["=", [!Select [2, "Fn::GetAZs": !Ref "AWS::Region"], !Ref PrivateRouteTable3]]
                ],
               !Ref "AWS::NoValue"
          ]
        ]
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
                          !Join [
                                  "+",
                                  [
                                    !Ref PublicSubnet,
                                    !If [DoAdditionalAz, !Ref PublicSubnet1a, !Ref "AWS::NoValue"]
                                  ]
                                ]
                        ]
                      ],
                !If [
                      DoAz1PrivateSubnet,
                      !Join [
                              ":",
                              [
                                !Select [0, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                                "private",
                                !Join [
                                        "+",
                                        [
                                          !Ref PrivateSubnet,
                                          !If [DoAz1aPrivateSubnet, !Ref PrivateSubnet1a, !Ref "AWS::NoValue"]
                                        ]
                                      ]
                              ]
                          ],
                      !Ref "AWS::NoValue"
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
                                !Join [
                                        "+",
                                        [
                                          !Ref PublicSubnet2
                                        ]
                                      ]
                              ]
                            ],
                      !If [
                            DoAz2PrivateSubnet,
                            !Join [
                                    ":",
                                    [
                                      !Select [1, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                                      "private",
                                      !Join [
                                              "+",
                                              [
                                                !Ref PrivateSubnet2
                                              ]
                                            ]
                                    ]
                                  ],
                            !Ref "AWS::NoValue"
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
                                !Join [
                                        "+",
                                        [
                                          !Ref PublicSubnet3
                                        ]
                                      ]
                              ]
                            ],
                      !If [
                            DoAz3PrivateSubnet,
                            !Join [
                                    ":",
                                    [
                                      !Select [2, !If [ "AzRestriction", !Ref AllowedAvailabilityZoneList, "Fn::GetAZs": !Ref "AWS::Region"]],
                                      "private",
                                      !Join [
                                              "+",
                                              [
                                                !Ref PrivateSubnet3
                                              ]
                                            ]
                                    ]
                                  ],
                            !Ref "AWS::NoValue"
                          ]
                    ]
                  ],
            ""
          ]
EOF

MAX_ZONES_COUNT=$(aws --region "${REGION}" ec2 describe-availability-zones --filter Name=state,Values=available Name=zone-type,Values=availability-zone | jq '.AvailabilityZones | length')
if (( ZONES_COUNT > MAX_ZONES_COUNT )); then
  ZONES_COUNT=$MAX_ZONES_COUNT
fi

# The above cloudformation template's max zones account is 3
if [[ "${ZONES_COUNT}" -gt 3 ]]; then
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

if [[ "${OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY}" == "true" ]]; then
    aws_add_param_to_json "OnlyPublicSubnets" "yes" "$vpc_params"
fi

if [[ -n "${VPC_CIDR}" ]]; then
     aws_add_param_to_json "VpcCidr" ${VPC_CIDR} "$vpc_params"
fi

if [[ "${ADDITIONAL_SUBNETS_COUNT}" -gt 0 ]]; then
  aws_add_param_to_json "AdditionalSubnetsCount" ${ADDITIONAL_SUBNETS_COUNT} "$vpc_params"
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
if [[ "${OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY}" != "true" ]]; then
    PrivateRouteTableId=$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="PrivateRouteTableIds") | .OutputValue | split(",")[0] | split("=")[1]' "${SHARED_DIR}/vpc_stack_output")
    echo "$PrivateRouteTableId" > "${SHARED_DIR}/private_route_table_id"
    echo "PrivateRouteTableId: ${PrivateRouteTableId}"
fi

# 
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

# # AZs
# # seperate by space
# # az1 az2 az3
# azs="$(jq -r '.Stacks[].Outputs[] | select(.OutputKey=="AvailabilityZones") | .OutputValue' "${SHARED_DIR}/vpc_stack_output" | sed 's/,/ /g')"
# echo "azs: $azs"
# for az in $azs;
# do
#   cat <<< "$(jq --arg az $az '.availability_zones += [$az]' ${vpc_info_json})" > ${vpc_info_json}
# done

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
