#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function generate_proxy_ignition() {
cat > /tmp/proxy.ign << EOF
{
  "ignition": {
    "config": {},
    "security": {
      "tls": {}
    },
    "timeouts": {},
    "version": "3.0.0"
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": [
          "${ssh_pub_key}"
        ]
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/etc/squid/passwords",
        "contents": {
          "source": "data:text/plain;base64,${HTPASSWD_CONTENTS}"
        },
        "mode": 420
      },
      {
        "path": "/etc/squid/squid.conf",
        "contents": {
          "source": "data:text/plain;base64,${SQUID_CONFIG}"
        },
        "mode": 420
      },
      {
        "path": "/etc/squid.sh",
        "contents": {
          "source": "data:text/plain;base64,${SQUID_SH}"
        },
        "mode": 420
      },
      {
        "path": "/etc/squid/proxy.sh",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_SH}"
        },
        "mode": 420
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "[Unit]\nWants=network-online.target\nAfter=network-online.target\n[Service]\n\nStandardOutput=journal+console\nExecStart=bash /etc/squid.sh\n\n[Install]\nRequiredBy=multi-user.target\n",
        "enabled": true,
        "name": "squid.service"
      },
      {
        "dropins": [
          {
            "contents": "[Service]\nExecStart=\nExecStart=/usr/lib/systemd/systemd-journal-gatewayd \\\n  --key=/opt/openshift/tls/journal-gatewayd.key \\\n  --cert=/opt/openshift/tls/journal-gatewayd.crt \\\n  --trust=/opt/openshift/tls/root-ca.crt\n",
            "name": "certs.conf"
          }
        ],
        "name": "systemd-journal-gatewayd.service"
      }
    ]
  }
}
EOF
}

function generate_proxy_template() {
cat > /tmp/04_cluster_proxy.yaml << EOF
AWSTemplateFormatVersion: 2010-09-09
Description: Template for OpenShift Cluster Proxy (EC2 Instance, Security Groups and IAM)

Parameters:
  InfrastructureName:
    AllowedPattern: ^([a-zA-Z][a-zA-Z0-9\-]{0,26})$
    MaxLength: 27
    MinLength: 1
    ConstraintDescription: Infrastructure name must be alphanumeric, start with a letter, and have a maximum of 27 characters.
    Description: A short, unique cluster ID used to tag cloud resources and identify items owned or used by the cluster.
    Type: String
  Ami:
    Description: Current CoreOS AMI to use for proxy.
    Type: AWS::EC2::Image::Id
  AllowedProxyCidr:
    AllowedPattern: ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])(\/([0-9]|1[0-9]|2[0-9]|3[0-2]))$
    ConstraintDescription: CIDR block parameter must be in the form x.x.x.x/0-32.
    Default: 0.0.0.0/0
    Description: CIDR block to allow access to the proxy node.
    Type: String
  ClusterName:
    Description: The cluster name used to uniquely identify the proxy load balancer
    Type: String
  PublicSubnet:
    Description: The public subnet to launch the proxy node into.
    Type: AWS::EC2::Subnet::Id
  VpcId:
    Description: The VPC-scoped resources will belong to this VPC.
    Type: AWS::EC2::VPC::Id
  ProxyIgnitionLocation:
    Default: s3://my-s3-bucket/proxy.ign
    Description: Ignition config file location.
    Type: String

Metadata:
  AWS::CloudFormation::Interface:
    ParameterGroups:
    - Label:
        default: "Cluster Information"
      Parameters:
      - InfrastructureName
    - Label:
        default: "Host Information"
      Parameters:
      - Ami
      - ProxyIgnitionLocation
    - Label:
        default: "Network Configuration"
      Parameters:
      - VpcId
      - AllowedProxyCidr
      - PublicSubnet
      - ClusterName

    ParameterLabels:
      InfrastructureName:
        default: "Infrastructure Name"
      VpcId:
        default: "VPC ID"
      AllowedProxyCidr:
        default: "Allowed ingress Source"
      Ami:
        default: "CoreOS AMI ID"
      ProxyIgnitionLocation:
        default: "Bootstrap Ignition Source"
      ClusterName:
        default: "Cluster name"

Resources:
  ProxyIamRole:
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
      - PolicyName: !Join ["-", [!Ref InfrastructureName, "proxy", "policy"]]
        PolicyDocument:
          Version: "2012-10-17"
          Statement:
          - Effect: "Allow"
            Action: "ec2:Describe*"
            Resource: "*"

  ProxyInstanceProfile:
    Type: "AWS::IAM::InstanceProfile"
    Properties:
      Path: "/"
      Roles:
      - Ref: "ProxyIamRole"

  ProxySecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Cluster Proxy Security Group
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        ToPort: 3128
        FromPort: 3128
        CidrIp: !Ref AllowedProxyCidr
      - IpProtocol: tcp
        ToPort: 19531
        FromPort: 19531
        CidrIp: !Ref AllowedProxyCidr
      VpcId: !Ref VpcId

  ProxyInstance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref Ami
      IamInstanceProfile: !Ref ProxyInstanceProfile
      KeyName: "openshift-dev"
      InstanceType: "m5.xlarge"
      NetworkInterfaces:
      - AssociatePublicIpAddress: "true"
        DeviceIndex: "0"
        GroupSet:
        - !Ref "ProxySecurityGroup"
        SubnetId: !Ref "PublicSubnet"
      UserData:
        Fn::Base64: !Sub
        - '{"ignition":{"config":{"replace":{"source":"\${IgnitionLocation}"}},"version":"3.0.0"}}'
        - {
          IgnitionLocation: !Ref ProxyIgnitionLocation
        }

Outputs:
  ProxyId:
    Description: The proxy node instanceId.
    Value: !Ref ProxyInstance
  ProxyPrivateIp:
    Description: The proxy node private IP address.
    Value: !GetAtt ProxyInstance.PrivateIp
  ProxyPublicIp:
    Description: The proxy node public IP address.
    Value: !GetAtt ProxyInstance.PublicIp
EOF
}

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

CONFIG="${SHARED_DIR}/install-config.yaml"

PROXY_IMAGE=registry.ci.openshift.org/origin/4.5:egress-http-proxy

PROXY_NAME="$(/tmp/yq r "${CONFIG}" 'metadata.name')"
REGION="$(/tmp/yq r "${CONFIG}" 'platform.aws.region')"
echo Using region: ${REGION}
test -n "${REGION}"

curl -L -o /tmp/fcos-stable.json https://builds.coreos.fedoraproject.org/streams/stable.json
AMI=$(jq -r .architectures.x86_64.images.aws.regions[\"${REGION}\"].image < /tmp/fcos-stable.json)
if [ -z "${AMI}" ]; then
  echo "Missing AMI in region: ${REGION}" 1>&2
  exit 1
fi
RELEASE=$(jq -r .architectures.x86_64.images.aws.regions[\"${REGION}\"].release < /tmp/fcos-stable.json)
echo "Using FCOS ${RELEASE} AMI: ${AMI}"

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")

# get the VPC ID from a subnet -> subnet.VpcId
aws_subnet="$(/tmp/yq r "${CONFIG}" 'platform.aws.subnets[0]')"
echo "Using aws_subnet: ${aws_subnet}"
vpc_id="$(aws --region "${REGION}" ec2 describe-subnets --subnet-ids "${aws_subnet}" | jq -r '.[][0].VpcId')"
echo "Using vpc_id: ${vpc_id}"

# for each subnet:
# aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=${value} | grep '"GatewayId": "igw.*'
  # if $? then use it as the public subnet

SUBNETS="$(/tmp/yq r -P "${CONFIG}" 'platform.aws.subnets' | sed 's/- //g')"
public_subnet=""
for subnet in ${SUBNETS}; do
  if aws --region "${REGION}" ec2 describe-route-tables --filters Name=association.subnet-id,Values="${subnet}" | grep '"GatewayId": "igw.*' 1>&2 > /dev/null; then
    public_subnet="${subnet}"
    break
  fi
done

if [[ -z "$public_subnet" ]]; then
  echo "Cound not find a public subnet in ${SUBNETS}" && exit 1
fi
echo "Using public_subnet: ${public_subnet}"

PASSWORD="$(uuidgen | sha256sum | cut -b -32)"
HTPASSWD_CONTENTS="${PROXY_NAME}:$(openssl passwd -apr1 ${PASSWORD})"
HTPASSWD_CONTENTS="$(echo -e ${HTPASSWD_CONTENTS} | base64 -w0)"

# define squid config
SQUID_CONFIG="$(base64 -w0 << EOF
http_port 3128
cache deny all
access_log stdio:/tmp/squid-access.log all
debug_options ALL,1
shutdown_lifetime 0
auth_param basic program /usr/lib64/squid/basic_ncsa_auth /squid/passwords
auth_param basic realm proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
pid_filename /tmp/proxy-setup
EOF
)"

# define squid.sh
SQUID_SH="$(base64 -w0 << EOF
#!/bin/bash
podman run --entrypoint='["bash", "/squid/proxy.sh"]' --expose=3128 --net host --volume /etc/squid:/squid:Z ${PROXY_IMAGE}
EOF
)"

# define proxy.sh
PROXY_SH="$(base64 -w0 << EOF
#!/bin/bash
function print_logs() {
    while [[ ! -f /tmp/squid-access.log ]]; do
    sleep 5
    done
    tail -f /tmp/squid-access.log
}
print_logs &
squid -N -f /squid/squid.conf
EOF
)"


# create ignition entries for certs and script to start squid and systemd unit entry
# create the proxy stack and then get its IP
PROXY_URI="s3://${PROXY_NAME}/proxy.ign"

generate_proxy_ignition
generate_proxy_template

# we need to be able to tear down the proxy even if install fails
# cannot rely on presence of ${SHARED_DIR}/metadata.json
echo "${REGION}" >> "${SHARED_DIR}/proxyregion"

# create the s3 bucket to push to
aws --region "${REGION}" s3 mb "s3://${PROXY_NAME}"
aws --region "${REGION}" s3api put-bucket-acl --bucket "${PROXY_NAME}" --acl public-read

# push the generated ignition to the s3 bucket
aws --region "${REGION}" s3 cp /tmp/proxy.ign "${PROXY_URI}"
aws --region "${REGION}" s3api put-object-acl --bucket "${PROXY_NAME}" --key "proxy.ign" --acl public-read

aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${PROXY_NAME}-proxy" \
  --template-body "$(cat "/tmp/04_cluster_proxy.yaml")" \
  --tags "${TAGS}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
  ParameterKey=ClusterName,ParameterValue="${PROXY_NAME}" \
  ParameterKey=VpcId,ParameterValue="${vpc_id}" \
  ParameterKey=ProxyIgnitionLocation,ParameterValue="${PROXY_URI}" \
  ParameterKey=InfrastructureName,ParameterValue="${PROXY_NAME}" \
  ParameterKey=Ami,ParameterValue="${AMI}" \
  ParameterKey=PublicSubnet,ParameterValue="${public_subnet}" &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${PROXY_NAME}-proxy" &
wait "$!"
echo "Waited for stack"

INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${PROXY_NAME}-proxy" \
--query 'Stacks[].Outputs[?OutputKey == `ProxyId`].OutputValue' --output text)"
echo "Instance ${INSTANCE_ID}"

# to allow log collection during gather:
# append to proxy instance ID to "${SHARED_DIR}/aws-instance-ids.txt"
echo "${INSTANCE_ID}" >> "${SHARED_DIR}/aws-instance-ids.txt"

PRIVATE_PROXY_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${PROXY_NAME}-proxy" \
  --query 'Stacks[].Outputs[?OutputKey == `ProxyPrivateIp`].OutputValue' --output text)"
PUBLIC_PROXY_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${PROXY_NAME}-proxy" \
  --query 'Stacks[].Outputs[?OutputKey == `ProxyPublicIp`].OutputValue' --output text)"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${PUBLIC_PROXY_IP}" >> "${SHARED_DIR}/proxyip"

PROXY_URL="http://${PROXY_NAME}:${PASSWORD}@${PRIVATE_PROXY_IP}:3128/"
# due to https://bugzilla.redhat.com/show_bug.cgi?id=1750650 we don't use a tls end point for squid

cat >> "${CONFIG}" << EOF
proxy:
  httpsProxy: ${PROXY_URL}
  httpProxy: ${PROXY_URL}
EOF
