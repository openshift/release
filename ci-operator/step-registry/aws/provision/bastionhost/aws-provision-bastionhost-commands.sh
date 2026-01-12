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
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi; save_stack_events_to_artifacts' EXIT TERM INT

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
if [[ ! -f "${SHARED_DIR}/vpc_id" && ! -f "${SHARED_DIR}/public_subnet_ids" ]] && [[ ! -f "${SHARED_DIR}/vpc_info.json" ]]; then
  if [[ ! -f ${SHARED_DIR}/metadata.json ]]; then
    echo "no vpc_id or public_subnet_ids found in ${SHARED_DIR} - and no metadata.json found, exiting"
    exit 1
  fi
  # for OCP
  echo "Reading infra id from file metadata.json"
  infra_id=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
  vpc_name="${infra_id}-vpc"
  public_subnet_name="${infra_id}-subnet-public-${REGION}a"
  echo "Looking up IDs for VPC ${vpc_name} and subnet ${public_subnet_name}"
  VpcId=$(aws --region ${REGION} ec2 describe-vpcs --filters Name=tag:"Name",Values=${vpc_name} --query 'Vpcs[0].VpcId' --output text)
  ### This finds any public subnet, as
  ### * we can't guess which azs are picked (public_subnet_name guesses its a)
  ### * pre-4.16 its ${infra_id}-subnet-public-${REGION}[abc...] and later 
  ### its ${infra_id}-public-${REGION}[abc...]
  ### any public subnet would work here
  PublicSubnet=$(aws --region ${REGION} ec2 describe-subnets --filters "Name=tag:kubernetes.io/cluster/${infra_id},Values=owned" "Name=tag:Name,Values=*public*" --query 'Subnets[0].SubnetId' --output text)
  ### This SG is created by AWS IPI since 4.18
  ### Previous versions or Byo-VPC may not have it created - 
  ### CloudFormation has logic to ignore it if its set to "None"
  ControlPlaneSecurityGroup=$(aws --region ${REGION} ec2 describe-security-groups --filters "Name=tag:sigs.k8s.io/cluster-api-provider-aws/cluster/${infra_id},Values=owned" "Name=tag:Name,Values=${infra_id}-controlplane" --query 'SecurityGroups[0].GroupId' --output text)
elif [[ -f "${SHARED_DIR}/vpc_info.json" ]]; then
  VpcId=$(jq -r '.vpc_id' "${SHARED_DIR}/vpc_info.json")
  PublicSubnet=$(jq -r '.subnets[0].ids[0].public' "${SHARED_DIR}/vpc_info.json")
  ControlPlaneSecurityGroup="None"
else
  VpcId=$(cat "${SHARED_DIR}/vpc_id")
  PublicSubnet=$(yq-go r "${SHARED_DIR}/public_subnet_ids" '[0]')
  ControlPlaneSecurityGroup="None"
fi

echo "VpcId: $VpcId"
echo "PublicSubnet: $PublicSubnet"
echo "ControlPlaneSecurityGroup: $ControlPlaneSecurityGroup"
EnableIpv6="no"
if [[ "${IPSTACK}" == "dualstack" ]]; then
    echo "IPSTACK: $IPSTACK"
    EnableIpv6="yes"
    VpcIpv6Cidr=$(jq -r '.vpc_ipv6_cidr //"2600:1f18:2b0a:7f00:aabb:aabb:aabb:aabb/128"' "${SHARED_DIR}/vpc_info.json")
fi

stack_name="${CLUSTER_NAME}-bas"
s3_bucket_name="${CLUSTER_NAME}-s3"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"
bastion_cf_tpl_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion-cf-tpl.yaml"


if [[ "${BASTION_HOST_AMI}" == "" ]]; then
  # create bastion host dynamicly
  if [[ ! -f "${bastion_ignition_file}" ]]; then
    echo "'${bastion_ignition_file}' not found , abort." && exit 1
  fi
  
  #
  # Use FCOS as bastion host, as systemd-resolved is only available in FCOS and it's involved in step bastion-dnsmasq,
  #   which is used by particular features (e.g. Custom DNS feature) 
  # But FCOS is not available in AWS GovCloud, so:
  #  a) use fixed FCOS AMI in GovCloud regions if aws-usgov-qe profile is used, this allow to test Custom DNS feature on GovCloud
  #  b) For other cases: aws-usgov cluster but not using aws-usgov-qe profile, still use rhcos images
  #
  if [[ "${CLUSTER_PROFILE_NAME:-}" == "aws-usgov-qe" ]]; then
    # the images are copied from on Jul. 3 2025
    # curl -sk https://builds.coreos.fedoraproject.org/streams/stable.json | jq -r '.architectures.x86_64.artifacts.aws.formats."vmdk.xz".disk.location'
    if [[ "${REGION}" == "us-gov-east-1" ]]; then
      ami_id="ami-086698edfd9b6933d"
    elif [[ "${REGION}" == "us-gov-west-1" ]]; then
      ami_id="ami-01cdd82c43022852b"
    fi
  else
    if [[ "${CLUSTER_TYPE}" == "aws-usgov" ]]; then
        bastion_image_list_url="https://raw.githubusercontent.com/openshift/installer/release-4.18/data/data/coreos/rhcos.json"
    else
        bastion_image_list_url="https://builds.coreos.fedoraproject.org/streams/stable.json"
    fi
        
    if ! curl -sSLf --retry 3 --connect-timeout 30 --max-time 60 -o /tmp/bastion-image.json "${bastion_image_list_url}"; then
        echo "ERROR: Failed to download RHCOS image list from ${bastion_image_list_url}" >&2
        exit 1
    fi
    
    if ! jq empty /tmp/bastion-image.json &>/dev/null; then
        echo "ERROR: Downloaded file is not valid JSON" >&2
        exit 1
    fi

    ami_id=$(jq -r --arg r ${REGION} '.architectures.x86_64.images.aws.regions[$r].image // ""' /tmp/bastion-image.json)
    if [[ ${ami_id} == "" ]]; then
        echo "Bastion host AMI was NOT found in region ${REGION}, exit now." && exit 1
    fi
  fi  

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
  VpcIpv6Cidr:
    ConstraintDescription: IPv6 CIDR block parameter
    Default: 2600:1f18:2b0a:7f00:aabb:aabb:aabb:aabb/128
    Description: IPv6 CIDR block for VPC.
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
  ControlPlaneSecurityGroup:
    Description: Control plane security group
    Type: String
  EnableIpv6:
    Default: "no"
    AllowedValues:
    - "yes"
    - "no"
    Type: String
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
  HasControlPlaneSecurityGroupSet: !Not [ !Equals ["None", !Ref ControlPlaneSecurityGroup] ]
  AssignIpv6: !Equals ["yes", !Ref EnableIpv6]

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
      GroupDescription: Bastion Host Security Group for ipv4
      SecurityGroupIngress:
      - IpProtocol: icmp
        FromPort: -1
        ToPort: -1
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
  BastionSecurityGroupIpv6:
    Condition: AssignIpv6
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Bastion Host Security Group for ipv6
      SecurityGroupIngress:
      - IpProtocol: icmpv6
        FromPort: -1
        ToPort: -1
        CidrIpv6: !Ref VpcIpv6Cidr
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 3128
        ToPort: 3129
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 5000
        ToPort: 5000
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 6001
        ToPort: 6002
        CidrIpv6: ::/0
      - IpProtocol: tcp
        FromPort: 80
        ToPort: 80
        CidrIpv6: ::/0
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
        Ipv6AddressCount: !If [ "AssignIpv6", 1, !Ref "AWS::NoValue"]
        GroupSet:
          - !GetAtt BastionSecurityGroup.GroupId
          - !If [ "AssignIpv6", !GetAtt BastionSecurityGroupIpv6.GroupId, !Ref "AWS::NoValue"]
          - !If [ "HasControlPlaneSecurityGroupSet", !Ref "ControlPlaneSecurityGroup", !Ref "AWS::NoValue"]
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
        ParameterKey=VpcIpv6Cidr,ParameterValue="${VpcIpv6Cidr-2600:1f18:2b0a:7f00:aabb:aabb:aabb:aabb/128}"  \
        ParameterKey=BastionHostInstanceType,ParameterValue="${BastionHostInstanceType}"  \
        ParameterKey=Machinename,ParameterValue="${stack_name}"  \
        ParameterKey=PublicSubnet,ParameterValue="${PublicSubnet}" \
        ParameterKey=ControlPlaneSecurityGroup,ParameterValue="${ControlPlaneSecurityGroup}" \
        ParameterKey=EnableIpv6,ParameterValue="${EnableIpv6}" \
        ParameterKey=AmiId,ParameterValue="${ami_id}" \
        ParameterKey=BastionIgnitionLocation,ParameterValue="${ign_location}"  &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}" &
wait "$!"
echo "Waited for stack"

INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
--query 'Stacks[].Outputs[?OutputKey == `BastionInstanceId`].OutputValue' --output text)"
echo "Instance ${INSTANCE_ID}"

# to allow log collection during gather:
# append to proxy bastion host ID to "${SHARED_DIR}/aws-instance-ids.txt"
echo "${INSTANCE_ID}" >> "${SHARED_DIR}/aws-instance-ids.txt"

if [[ "${EnableIpv6}" == "yes" ]]; then
    BASTION_HOST_IPv6="$(aws --region "${REGION}" ec2 describe-instances --instance-ids ${INSTANCE_ID} \
--query "Reservations[*].Instances[].Ipv6Address" --output text)"
    echo "Bastion IPv6: ${BASTION_HOST_IPv6}"
    echo "${BASTION_HOST_IPv6}" > "${SHARED_DIR}/bastion_ipv6_address"
fi

BASTION_HOST_PUBLIC_DNS="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PublicDnsName`].OutputValue' --output text)"
BASTION_HOST_PRIVATE_DNS="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
  --query 'Stacks[].Outputs[?OutputKey == `PrivateDnsName`].OutputValue' --output text)"

echo "${BASTION_HOST_PUBLIC_DNS}" > "${SHARED_DIR}/bastion_public_address"
echo "${BASTION_HOST_PRIVATE_DNS}" > "${SHARED_DIR}/bastion_private_address"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${BASTION_HOST_PUBLIC_DNS}" > "${SHARED_DIR}/proxyip"

if [[ "${CUSTOM_PROXY_CREDENTIAL}" == "true" ]]; then
    PROXY_CREDENTIAL=$(< /var/run/vault/proxy/custom_proxy_creds)
else
    PROXY_CREDENTIAL=$(< /var/run/vault/proxy/proxy_creds)
fi
PROXY_PUBLIC_URL="http://${PROXY_CREDENTIAL}@${BASTION_HOST_PUBLIC_DNS}:3128"
PROXY_PRIVATE_URL="http://${PROXY_CREDENTIAL}@${BASTION_HOST_PRIVATE_DNS}:3128"
PROXY_PRIVATE_HTTPS_URL="https://${PROXY_CREDENTIAL}@${BASTION_HOST_PRIVATE_DNS}:3129"

echo "${PROXY_PUBLIC_URL}" > "${SHARED_DIR}/proxy_public_url"
echo "${PROXY_PRIVATE_URL}" > "${SHARED_DIR}/proxy_private_url"
echo "${PROXY_PRIVATE_HTTPS_URL}" > "${SHARED_DIR}/proxy_private_https_url"

MIRROR_REGISTRY_URL="${BASTION_HOST_PUBLIC_DNS}:5000"
echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"

echo "Sleeping 5 mins, make sure that the bastion host is fully started."
sleep 300
