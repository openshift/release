#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save stacks events
trap 'save_stack_events_to_artifacts' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION=${REGION:-$LEASED_RESOURCE}

function save_stack_events_to_artifacts()
{
  set +o errexit
  aws --region ${REGION} cloudformation describe-stack-events --stack-name ${stack_name} --output json > "${ARTIFACT_DIR}/stack-events-${stack_name}.json"
  set -o errexit
}

# Using source region for C2S and SC2S
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  REGION=$(jq -r ".\"${LEASED_RESOURCE}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
# 1. get vpc id and public subnet
if [[ ! -f "${SHARED_DIR}/vpc_id" && ! -f "${SHARED_DIR}/public_subnet_ids" ]]; then
  if [[ ! -f ${SHARED_DIR}/metadata.json ]]; then
    echo "no vpc_id or public_subnet_ids found in ${SHARED_DIR} - and no metadata.json found, exiting"
    exit 1
  fi
  # for OCP
  echo "Reading infra id from file metadata.json"
  infra_id=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
  echo "Looking up IDs for VPC ${infra_id} and subnet ${infra_id}-public-${REGION}a"
  VpcId=$(aws --region ${REGION} ec2 describe-vpcs --filters Name=tag:"Name",Values=${infra_id}-vpc --query 'Vpcs[0].VpcId' --output text)
  PublicSubnet=$(aws --region ${REGION} ec2 describe-subnets --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" "Name=tag:Name,Values=*public*" --query 'Subnets[0].SubnetId' --output text)
else
  VpcId=$(cat "${SHARED_DIR}/vpc_id")
  PublicSubnet="$(yq-go r "${SHARED_DIR}/public_subnet_ids" '[0]')"
fi
echo "VpcId: $VpcId"
echo "PublicSubnet: $PublicSubnet"

stack_name="${CLUSTER_NAME}-bas"
s3_bucket_name="${CLUSTER_NAME}-s3"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"
bastion_cf_tpl_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion-cf-tpl.yaml"


if [[ "${BASTION_HOST_AMI}" == "" ]]; then
  # create bastion host dynamicly
  if [[ ! -f "${bastion_ignition_file}" ]]; then
    echo "'${bastion_ignition_file}' not found , abort." && exit 1
  fi
  curl -sL https://raw.githubusercontent.com/yunjiang29/ocp-test-data/main/coreos-for-bastion-host/fedora-coreos-stable.json -o /tmp/fedora-coreos-stable.json
  ami_id=$(jq -r .architectures.x86_64.images.aws.regions[\"${REGION}\"].image < /tmp/fedora-coreos-stable.json)

  ign_location="s3://${s3_bucket_name}/bastion.ign"
  aws --region $REGION s3 mb "s3://${s3_bucket_name}"
  echo "s3://${s3_bucket_name}" > "$SHARED_DIR/to_be_removed_s3_bucket_list"
  aws --region $REGION s3 cp ${bastion_ignition_file} "${ign_location}"
  echo "core" > "${SHARED_DIR}/bastion_ssh_user"
else
  # use BYO bastion host
  ami_id=${BASTION_HOST_AMI}
  ign_location="NA"
  echo "ec2-user" > "${SHARED_DIR}/bastion_ssh_user"
fi

echo -e "AMI ID: $ami_id"

BastionHostInstanceType="t2.medium"
# there is no t2.medium instance type in us-gov-east-1 region
if [[ "${REGION}" == "us-gov-east-1" ]]; then
    BastionHostInstanceType="t3a.medium"
fi

## ----------------------------------------------------------------
# bastion host CF template
## ----------------------------------------------------------------
cat > ${bastion_cf_tpl_file} << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for RHEL machine Launch

Parameters:
  VpcCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/(1[6-9]|2[0-4]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/16-24.
    Default: 10.0.0.0/16
    Description: CIDR block for VPC.
    Type: String
  VpcId:
    Description: The VPC-scoped resources will belong to this VPC.
    Type: AWS::EC2::VPC::Id
  AmiId:
    Description: Current CoreOS AMI to use for proxy.
    Type: AWS::EC2::Image::Id
  Machinename:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Machinename
    Description: Machinename
    Type: String
    Default: qe-dis-registry-proxy
  PublicSubnet:
    Description: The subnets (recommend public) to launch the registry nodes into
    Type: AWS::EC2::Subnet::Id
  BastionHostInstanceType:
    Default: t2.medium
    Type: String
  BastionIgnitionLocation:
    Description: Ignition config file location.
    Default: NA
    Type: String

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Host Information"
      Parameters:
      - BastionHostInstanceType
    - Label:
        default: "Network Configuration"
      Parameters:
      - PublicSubnet
    ParameterLabels:
      PublicSubnet:
        default: "Worker Subnet"
      BastionHostInstanceType:
        default: "Worker Instance Type"

Conditions:
  UseIgnition: !Not [ !Equals ["NA", !Ref BastionIgnitionLocation] ]

Resources:
  BastionIamRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: "2012-10-17"
        Statement:
        - Effect: "Allow"
          Principal:
            Service:
            - "ec2.amazonaws.com"
          Action:
          - "sts:AssumeRole"
      Path: "/"
      Policies:
      - PolicyName: !Join ["-", [!Ref Machinename, "policy"]]
        PolicyDocument:
          Version: "2012-10-17"
          Statement:
          - Effect: "Allow"
            Action: "s3:Get*"
            Resource: "*"
          - Effect: "Allow"
            Action: "s3:List*"
            Resource: "*"
  BastionInstanceProfile:
    Type: "AWS::IAM::InstanceProfile"
    Properties:
      Path: "/"
      Roles:
      - Ref: "BastionIamRole"
  BastionSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Bastion Host Security Group
      SecurityGroupIngress:
      - IpProtocol: icmp
        FromPort: 0
        ToPort: 0
        CidrIp: !Ref VpcCidr
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 873
        ToPort: 873
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 3128
        ToPort: 3128
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 3129
        ToPort: 3129
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 5000
        ToPort: 5000
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 6001
        ToPort: 6002
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 80
        ToPort: 80
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 8080
        ToPort: 8080
        CidrIp: 0.0.0.0/0
      VpcId: !Ref VpcId
  BastionInstance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      IamInstanceProfile: !Ref BastionInstanceProfile
      InstanceType: !Ref BastionHostInstanceType
      NetworkInterfaces:
      - AssociatePublicIpAddress: "True"
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt BastionSecurityGroup.GroupId
        SubnetId: !Ref "PublicSubnet"
      Tags:
      - Key: Name
        Value: !Join ["", [!Ref Machinename]]
      BlockDeviceMappings:
        !If
          - "UseIgnition"
          - - DeviceName: /dev/xvda
              Ebs:
                VolumeSize: "500"
                VolumeType: gp2
          - - DeviceName: /dev/sda1
              Ebs:
                VolumeSize: "500"
                VolumeType: gp2
      UserData:
        !If
          - "UseIgnition"
          - Fn::Base64:
              !Sub
                - '{"ignition":{"config":{"replace":{"source":"\${IgnitionLocation}"}},"version":"3.0.0"}}'
                - IgnitionLocation: !Ref BastionIgnitionLocation
          - !Ref "AWS::NoValue"

Outputs:
  BastionInstanceId:
    Description: Bastion Host Instance ID
    Value: !Ref BastionInstance
  BastionSecurityGroupId:
    Description: Bastion Host Security Group ID
    Value: !GetAtt BastionSecurityGroup.GroupId
  PublicDnsName:
    Description: The bastion host node Public DNS, will be used for release image mirror from slave
    Value: !GetAtt BastionInstance.PublicDnsName
  PrivateDnsName:
    Description: The bastion host Private DNS, will be used for cluster install pulling release image
    Value: !GetAtt BastionInstance.PrivateDnsName
  PublicIp:
    Description: The bastion host Public IP, will be used for registering minIO server DNS
    Value: !GetAtt BastionInstance.PublicIp
EOF


# create bastion instance bucket
echo -e "==== Start to create bastion host ===="
echo ${stack_name} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
aws --region $REGION cloudformation create-stack --stack-name ${stack_name} \
    --template-body file://${bastion_cf_tpl_file} \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
        ParameterKey=VpcId,ParameterValue="${VpcId}"  \
        ParameterKey=BastionHostInstanceType,ParameterValue="${BastionHostInstanceType}"  \
        ParameterKey=Machinename,ParameterValue="${stack_name}"  \
        ParameterKey=PublicSubnet,ParameterValue="${PublicSubnet}" \
        ParameterKey=AmiId,ParameterValue="${ami_id}" \
        ParameterKey=BastionIgnitionLocation,ParameterValue="${ign_location}"  &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}" &
wait "$!"
echo "Waited for stack"

echo "$stack_name" > "${SHARED_DIR}/bastion_host_stack_name"

INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
--query 'Stacks[].Outputs[?OutputKey == `BastionInstanceId`].OutputValue' --output text)"
echo "Instance ${INSTANCE_ID}"

# to allow log collection during gather:
# append to proxy bastion host ID to "${SHARED_DIR}/aws-instance-ids.txt"
echo "${INSTANCE_ID}" >> "${SHARED_DIR}/aws-instance-ids.txt"

BASTION_HOST_PUBLIC_DNS="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PublicDnsName`].OutputValue' --output text)"
BASTION_HOST_PRIVATE_DNS="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PrivateDnsName`].OutputValue' --output text)"

echo "${BASTION_HOST_PUBLIC_DNS}" > "${SHARED_DIR}/bastion_public_address"
echo "${BASTION_HOST_PRIVATE_DNS}" > "${SHARED_DIR}/bastion_private_address"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${BASTION_HOST_PUBLIC_DNS}" > "${SHARED_DIR}/proxyip"

PROXY_CREDENTIAL=$(< /var/run/vault/proxy/proxy_creds)
PROXY_PUBLIC_URL="http://${PROXY_CREDENTIAL}@${BASTION_HOST_PUBLIC_DNS}:3128"
PROXY_PRIVATE_URL="http://${PROXY_CREDENTIAL}@${BASTION_HOST_PRIVATE_DNS}:3128"

echo "${PROXY_PUBLIC_URL}" > "${SHARED_DIR}/proxy_public_url"
echo "${PROXY_PRIVATE_URL}" > "${SHARED_DIR}/proxy_private_url"

MIRROR_REGISTRY_URL="${BASTION_HOST_PUBLIC_DNS}:5000"
echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"

echo "Sleeping 5 mins, make sure that the bastion host is fully started."
sleep 300
