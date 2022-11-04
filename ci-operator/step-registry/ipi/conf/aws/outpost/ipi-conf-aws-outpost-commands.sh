#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

function join_by { local IFS="$1"; shift; echo "$*"; }

# EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
# TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-outpost.yaml.patch
REGION="${REGION:-$LEASED_RESOURCE}"
CLUSTER_NAME="$(yq-go r "${CONFIG}" 'metadata.name')"

export REGION='us-east-1'

OUTPOST_ID=$(aws --region "${REGION}" outposts list-outposts | jq -r .Outposts[0].OutpostId)
OUTPOST_AZ=$(aws --region "${REGION}" outposts list-outposts | jq -r .Outposts[0].AvailabilityZone)
OUTPOST_ARN=$(aws --region "${REGION}" outposts list-outposts | jq -r .Outposts[0].OutpostArn)
OUTPOST_INSTANCE_TYPE=$(aws --region "${REGION}" outposts get-outpost-instance-types --outpost-id $OUTPOST_ID | jq -r .InstanceTypes[1].InstanceType)

cat <<_EOF > /tmp/01_vpc.yaml
AWSTemplateFormatVersion: 2010-09-09
Description: Template for Best Practice VPC with 1-3 AZs

Parameters:
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.0.0/16
    Description: CIDR block for VPC.
    Type: String
  SubnetBits:
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/19-27.
    MinValue: 5
    MaxValue: 13
    Default: 12
    Description: "Size of each subnet to create within the availability zones. (Min: 5 = /27, Max: 13 = /19)"
    Type: Number
  AvailabilityZone:
    ConstraintDescription: The availbility zone used by the outpost instance
    Description: AWS Outpost Availability Zone.
    Type: String
  OutpostArn:
    ConstraintDescription: The Amazon Resource Name (ARN) of the Outpost.
    Description: The Amazon Resource Name (ARN) of the Outpost.
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
        default: "Availability Zone"
      Parameters:
      - AvailabilityZone
      - OutpostArn
    ParameterLabels:
      VpcCidr:
        default: "VPC CIDR"
      SubnetBits:
        default: "Bits Per Subnet"
      AvailabilityZone:
        default: "Availability Zone"
      OutpostArn:
        default: "Outpost Arn"

Resources:
  VPC:
    Type: "AWS::EC2::VPC"
    Properties:
      EnableDnsSupport: "true"
      EnableDnsHostnames: "true"
      CidrBlock: !Ref VpcCidr
  PublicSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [0, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      AvailabilityZone: !Ref AvailabilityZone
  PublicSubnetOutpost:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [1, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      AvailabilityZone: !Ref AvailabilityZone
      OutpostArn: !Ref OutpostArn
      Tags:
      - Key: "kubernetes.io/cluster/outpost-tag"
        Value: "owned"
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
  PublicSubnetRouteTableAssociationOutpost:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PublicSubnetOutpost
      RouteTableId: !Ref PublicRouteTable
  PrivateSubnet:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [2, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      AvailabilityZone: !Ref AvailabilityZone
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
  PrivateSubnetOutpost:
    Type: "AWS::EC2::Subnet"
    Properties:
      VpcId: !Ref VPC
      CidrBlock: !Select [3, !Cidr [!Ref VpcCidr, 6, !Ref SubnetBits]]
      AvailabilityZone: !Ref AvailabilityZone
      OutpostArn: !Ref OutpostArn
      Tags:
      - Key: "kubernetes.io/cluster/outpost-tag"
        Value: "owned"
  PrivateRouteTableOutpost:
    Type: "AWS::EC2::RouteTable"
    Properties:
      VpcId: !Ref VPC
  PrivateSubnetRouteTableAssociationOutpost:
    Type: "AWS::EC2::SubnetRouteTableAssociation"
    Properties:
      SubnetId: !Ref PrivateSubnetOutpost
      RouteTableId: !Ref PrivateRouteTableOutpost
  NATOutpost:
    DependsOn:
    - GatewayToInternet
    Type: "AWS::EC2::NatGateway"
    Properties:
      AllocationId:
        "Fn::GetAtt":
        - EIPOutpost
        - AllocationId
      SubnetId: !Ref PublicSubnetOutpost
  EIPOutpost:
    Type: "AWS::EC2::EIP"
    Properties:
      Domain: vpc
  RouteOutpost:
    Type: "AWS::EC2::Route"
    Properties:
      RouteTableId:
        Ref: PrivateRouteTableOutpost
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId:
        Ref: NATOutpost
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
      ServiceName: !Join
      - ''
      - - com.amazonaws.
        - !Ref 'AWS::Region'
        - .s3
      VpcId: !Ref VPC

Outputs:
  VpcId:
    Description: ID of the new VPC.
    Value: !Ref VPC
  PublicSubnetIds:
    Description: Subnet IDs of the public subnets.
    Value:
      !Join [
        ",",
        [!Ref PublicSubnet]
      ]
  PrivateSubnetIds:
    Description: Subnet IDs of the private subnets.
    Value:
      !Join [
        ",",
        [!Ref PrivateSubnet]
      ]
  OutpostPublicSubnetId:
    Description: Subnet ID of the public subnet in Outpost.
    Value:
      !Ref PublicSubnetOutpost
  OutpostPrivateSubnetId:
    Description: Subnet ID of the private subnet in Outpost.
    Value:
      !Ref PrivateSubnetOutpost
_EOF

STACK_NAME="${CLUSTER_NAME}-outpost-vpc"
echo "${STACK_NAME}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"  # save stack information to ${SHARED_DIR} for deprovision step
echo "${STACK_NAME}" > "${SHARED_DIR}/outpost_stack"                 # save stack information to ${SHARED_DIR} for deprovision step

aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME}" \
  --template-body "$(cat /tmp/01_vpc.yaml)" \
  --parameters \
    ParameterKey=AvailabilityZone,ParameterValue="${OUTPOST_AZ}" \
    ParameterKey=OutpostArn,ParameterValue="${OUTPOST_ARN}" &
# --tags "${TAGS}" \

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}" &
wait "$!"
echo "Waited for stack"

subnets="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]' | sed "s/\"/'/g")"
echo "Subnets : ${subnets}"


yq-go d -i "${CONFIG}" 'controlPlane.platform.aws.zones'  # remove current controlPlane.aws.zones
yq-go d -i "${CONFIG}" 'compute[0].platform.aws.zones'    # remove current compute.aws.zones

cat > "${PATCH}" << EOF
platform:
  aws:
    region: $REGION
    subnets: ${subnets}
compute:
- platform:
    aws:
      zones:
        - $OUTPOST_AZ
      type: $OUTPOST_INSTANCE_TYPE
      rootVolume:
        type: gp2
        size: 120
EOF
yq-go m -i -x "${CONFIG}" "${PATCH}"                      # merge $PATCH with $CONFIG


# Save outpost subnets, and yml for later use in ipi-install-install 
echo $(aws --region "${REGION}" cloudformation describe-stacks --stack-name $STACK_NAME |jq -r '.Stacks |.[].Outputs|.[] |select(.OutputKey=="PrivateSubnetIds").OutputValue') > $SHARED_DIR/prv_subn
echo $(aws --region "${REGION}" cloudformation describe-stacks --stack-name $STACK_NAME |jq -r '.Stacks |.[].Outputs|.[] |select(.OutputKey=="OutpostPrivateSubnetId").OutputValue') > $SHARED_DIR/outpost_prv_subn

NET='ovnKubernetesConfig:'
MTU='1200'
if [[ "$(yq-go r ${CONFIG} 'networking.networkType')" == "OpenShiftSDN" ]]; then
  NET='openshiftSDNConfig:'
  MTU='1250'
fi
cat << _EOF > $SHARED_DIR/cluster-network-03-config.yml
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  defaultNetwork:
    $NET
      $MTU
_EOF

ls -l "${SHARED_DIR}"
cat "${CONFIG}"
