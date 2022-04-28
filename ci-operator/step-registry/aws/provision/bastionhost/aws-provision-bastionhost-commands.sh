#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

REGION="${LEASED_RESOURCE}"

# Using source region for C2S and SC2S
if [[ "${CLUSTER_TYPE}" == "aws-c2s" ]] || [[ "${CLUSTER_TYPE}" == "aws-sc2s" ]]; then
  REGION=$(jq -r ".\"${LEASED_RESOURCE}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
fi

# 1. get vpc id and public subnet
VpcId=$(cat "${SHARED_DIR}/vpc_id")
echo "VpcId: $VpcId"

PublicSubnet="$(/tmp/yq r "${SHARED_DIR}/public_subnet_ids" '[0]')"
echo "PublicSubnet: $PublicSubnet"

stack_name="${NAMESPACE}-${JOB_NAME_HASH}-bas"
s3_bucket_name="${NAMESPACE}-${JOB_NAME_HASH}-s3"

BastionHostInstanceType="t2.medium"
# there is no t2.medium instance type in us-gov-east-1 region
if [ "${REGION}" == "us-gov-east-1" ]; then
    BastionHostInstanceType="t3a.medium"
fi

ssh_pub_key=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")

workdir=`mktemp -d`

echo -e "==== Start to create bastion host ===="
echo -e "working dir: $workdir"

# TODO: move repo to a more appropriate location
if [ "${BASTION_HOST_AMI}" == "" ]; then
  curl -sL https://raw.githubusercontent.com/yunjiang29/ocp-test-data/main/coreos-for-bastion-host/fedora-coreos-stable.json -o $workdir/fedora-coreos-stable.json
  ami_id=$(jq -r .architectures.x86_64.images.aws.regions[\"${REGION}\"].image < $workdir/fedora-coreos-stable.json)
else
  ami_id=${BASTION_HOST_AMI}
fi

echo -e "AMI ID: $ami_id"

## ----------------------------------------------------------------
# bastion host CF template
## ----------------------------------------------------------------
cat > ${workdir}/bastion.yaml << EOF
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
        - DeviceName: /dev/xvda
          Ebs:
            VolumeSize: "120"
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

## ----------------------------------------------------------------
## Generate ignition file for dynamic host
## ----------------------------------------------------------------

bastion_ignition_file="${workdir}/bastion.ign"

function patch_ignition_file()
{
  local base_ignition=$1
  local patch_ignition=$2
  t=$(mktemp)
  # jq deepmerge 
  # https://stackoverflow.com/questions/53661930/jq-recursively-merge-objects-and-concatenate-arrays
  jq -s 'def deepmerge(a;b):
  reduce b[] as $item (a;
    reduce ($item | keys_unsorted[]) as $key (.;
      $item[$key] as $val | ($val | type) as $type | .[$key] = if ($type == "object") then
        deepmerge({}; [if .[$key] == null then {} else .[$key] end, $val])
      elif ($type == "array") then
        (.[$key] + $val | unique)
      else
        $val
      end)
    );
  deepmerge({}; .)' "${base_ignition}" "${patch_ignition}" > "${t}"
  mv "${t}" "${base_ignition}"
  rm -f "${t}"
}

# base iignition
cat > "${bastion_ignition_file}" << EOF
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
    ],
    "directories": [
    ]
  },
  "systemd": {
    "units": [
      {
        "enabled": false,
        "mask": true,
        "name": "zincati.service"
      }
    ]
  }
}
EOF


# ----------------------------------------------------------------
# PROXY ignition
# /srv/squid/etc/passwords
# /srv/squid/etc/mime.conf
# /srv/squid/etc/squid.conf
# /srv/squid/log/
# /srv/squid/cache
# ----------------------------------------------------------------

## PROXY Config
cat > ${workdir}/squid.conf << EOF
auth_param basic program /usr/lib64/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic realm proxy

acl authenticated proxy_auth REQUIRED
acl CONNECT method CONNECT
http_access allow authenticated
http_port 3128
EOF

## PROXY Service
cat > ${workdir}/squid-proxy.service << EOF
[Unit]
Description=OpenShift QE Squid Proxy Server
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "squid-proxy"

ExecStart=/usr/bin/podman run   --name "squid-proxy" \
                                --net host \
                                -p 3128:3128 \
                                -p 3129:3129 \
                                -v /srv/squid/etc:/etc/squid:Z \
                                -v /srv/squid/cache:/var/spool/squid:Z \
                                -v /srv/squid/log:/var/log/squid:Z \
                                quay.io/crcont/squid

ExecReload=-/usr/bin/podman stop "squid-proxy"
ExecReload=-/usr/bin/podman rm "squid-proxy"
ExecStop=-/usr/bin/podman stop "squid-proxy"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

PROXY_CREDENTIAL=$(< /var/run/vault/proxy/proxy_creds)
PROXY_CREDENTIAL_ARP1=$(< /var/run/vault/proxy/proxy_creds_encrypted_apr1)
PROXY_CREDENTIAL_CONTENT="$(echo -e ${PROXY_CREDENTIAL_ARP1} | base64 -w0)"
PROXY_CONFIG_CONTENT=$(cat ${workdir}/squid.conf | base64 -w0)
PROXY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' ${workdir}/squid-proxy.service | sed 's/\"/\\"/g')

# proxy ignition
proxy_ignition_patch=$(mktemp)
cat > "${proxy_ignition_patch}" << EOF
{
  "storage": {
    "files": [
      {
        "path": "/srv/squid/etc/passwords",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_CREDENTIAL_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/etc/squid.conf",
        "contents": {
          "source": "data:text/plain;base64,${PROXY_CONFIG_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/srv/squid/etc/mime.conf",
        "contents": {
          "source": "data:text/plain;base64,"
        },
        "mode": 420
      }
    ],
    "directories": [
      {
        "path": "/srv/squid/log",
        "mode": 493
      },
      {
        "path": "/srv/squid/cache",
        "mode": 493
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "${PROXY_SERVICE_CONTENT}",
        "enabled": true,
        "name": "squid-proxy.service"
      }
    ]
  }
}
EOF

# patch proxy setting to ignition
patch_ignition_file "${bastion_ignition_file}" "${proxy_ignition_patch}"
rm -f "${proxy_ignition_patch}"



## ----------------------------------------------------------------
# MIRROR REGISTORY
# /opt/registry-$port/auth/htpasswd
# /opt/registry-$port/certs/domain.crt
# /opt/registry-$port/certs/domain.key
# /opt/registry-$port/data
# 
## ----------------------------------------------------------------

function gen_registry_service_file() {
  local port="$1"
  local output="$2"
  cat > "${output}" << EOF
[Unit]
Description=OpenShift POC HTTP for PXE Config
After=network.target syslog.target

[Service]
Type=simple
TimeoutStartSec=5m
ExecStartPre=-/usr/bin/podman rm "poc-registry-${port}"
ExecStartPre=/usr/bin/chcon -Rt container_file_t /opt/registry-${port}


ExecStart=/usr/bin/podman run   --name poc-registry-${port} \
                                -p ${port}:${port} \
                                --net host \
                                -v /opt/registry-${port}/data:/var/lib/registry:z \
                                -v /opt/registry-${port}/auth:/auth \
                                -v /opt/registry-${port}/certs:/certs:z \
                                -v /opt/registry-${port}/config.yaml:/etc/docker/registry/config.yml \
                                registry:2

ExecReload=-/usr/bin/podman stop "poc-registry-${port}"
ExecReload=-/usr/bin/podman rm "poc-registry-${port}"
ExecStop=-/usr/bin/podman stop "poc-registry-${port}"
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
}

function gen_registry_config_file() {
  local port="$1"
  local output="$2"
  cat > "${output}" << EOF
version: 0.1
log:
  fields:
    service: registry
http:
  addr: :${port}
  headers:
    X-Content-Type-Options: [nosniff]
  tls:
    certificate: /certs/domain.crt
    key: /certs/domain.key
storage:
  cache:
    blobdescriptor: inmemory
  filesystem:
    rootdirectory: /opt/registry-${port}
auth:
  htpasswd:
    realm: Registry Realm
    path: /auth/htpasswd
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
EOF
}

REGISTRY_PASSWORD_CONTENT=$(cat "/var/run/vault/mirror-registry/registry_creds_encrypted_htpasswd" | base64 -w0)
REGISTRY_CRT_CONTENT=$(cat "/var/run/vault/mirror-registry/server_domain.crt" | base64 -w0)
REGISTRY_KEY_CONTENT=$(cat "/var/run/vault/mirror-registry/server_domain.pem" | base64 -w0)

declare -a registry_ports=("5000" "6001" "6002")

for port in "${registry_ports[@]}"; do
  registry_service_file="${workdir}/registry_service_file_$port"
  registry_config_file="${workdir}/registry_config_file_$port"

  gen_registry_service_file $port "${registry_service_file}"
  gen_registry_config_file $port "${registry_config_file}"
done

# special custom configurations for individual registry register
patch_file=$(mktemp)

# patch proxy for 6001 quay.io
reg_quay_url=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.url')
reg_quay_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
reg_quay_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
cat > "${patch_file}" << EOF
proxy:
  remoteurl: "${reg_quay_url}"
  username: "${reg_quay_user}"
  password: "${reg_quay_password}"
EOF
/tmp/yq m -x -i "${workdir}/registry_config_file_6001" "${patch_file}"

# patch proxy for 6002 brew.registry.redhat.io
reg_brew_url=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.url')
reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
cat > "${patch_file}" << EOF
proxy:
  remoteurl: "${reg_brew_url}"
  username: "${reg_brew_user}"
  password: "${reg_brew_password}"
EOF
/tmp/yq m -x -i "${workdir}/registry_config_file_6002" "${patch_file}"

rm -f "${patch_file}"

for port in "${registry_ports[@]}"; do
  registry_service_file="${workdir}/registry_service_file_$port"
  registry_config_file="${workdir}/registry_config_file_$port"

  # adjust system unit content to ignition format
  #   replace [newline] with '\n', and replace '"' with '\"'
  #   https://stackoverflow.com/questions/1251999/how-can-i-replace-a-newline-n-using-sed
  REGISTRY_SERVICE_CONTENT=$(sed ':a;N;$!ba;s/\n/\\n/g' "${registry_service_file}" | sed 's/\"/\\"/g')
  REGISTRY_CONFIG_CONTENT=$(cat "${registry_config_file}" | base64 -w0)

  registry_ignition_patch=$(mktemp)
  cat > "${registry_ignition_patch}" << EOF
{
  "storage": {
    "files": [
      {
        "path": "/opt/registry-${port}/auth/htpasswd",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_PASSWORD_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry-${port}/certs/domain.crt",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_CRT_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry-${port}/certs/domain.key",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_KEY_CONTENT}"
        },
        "mode": 420
      },
      {
        "path": "/opt/registry-${port}/config.yaml",
        "contents": {
          "source": "data:text/plain;base64,${REGISTRY_CONFIG_CONTENT}"
        },
        "mode": 420
      }
    ],
    "directories": [
      {
        "path": "/opt/registry-${port}/data",
        "mode": 493
      }
    ]
  },
  "systemd": {
    "units": [
      {
        "contents": "${REGISTRY_SERVICE_CONTENT}",
        "enabled": true,
        "name": "poc-registry-${port}.service"
      }
    ]
  }
}
EOF

  # patch proxy setting to ignition
  patch_ignition_file "${bastion_ignition_file}" "${registry_ignition_patch}"
  rm -f "${registry_ignition_patch}"
done

# upload ignition file to s3
if [ "${BASTION_HOST_AMI}" == "" ]; then
  ign_location="s3://${s3_bucket_name}/bastion.ign"
  aws --region $REGION s3 mb "s3://${s3_bucket_name}"
  echo "s3://${s3_bucket_name}" > "$SHARED_DIR/to_be_removed_s3_bucket_list"
  aws --region $REGION s3 cp ${workdir}/bastion.ign "${ign_location}"
else
  ign_location="NA"
fi


## ----------------------------------------------------------------
## End of generate ignition file for dynamic host
## ----------------------------------------------------------------

# create bastion instance bucket
echo ${stack_name} >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
aws --region $REGION cloudformation create-stack --stack-name ${stack_name} \
    --template-body file://${workdir}/bastion.yaml \
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
echo "core" > "${SHARED_DIR}/bastion_ssh_user"

PROXY_PUBLIC_URL="http://${PROXY_CREDENTIAL}@${BASTION_HOST_PUBLIC_DNS}:3128"
PROXY_PRIVATE_URL="http://${PROXY_CREDENTIAL}@${BASTION_HOST_PRIVATE_DNS}:3128"

echo "${PROXY_PUBLIC_URL}" > "${SHARED_DIR}/proxy_public_url"
echo "${PROXY_PRIVATE_URL}" > "${SHARED_DIR}/proxy_private_url"

MIRROR_REGISTRY_URL="${BASTION_HOST_PUBLIC_DNS}:5000"
echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"

echo "Sleeping 5 mins, make sure that the bastion host is fully started."
sleep 300
