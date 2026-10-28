#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

region="${REGION:-$LEASED_RESOURCE}"
job_tag="${NAMESPACE}-${UNIQUE_HASH}"
stack_name="${job_tag}-qsha"
db_name=quay
db_user=quay
template_file=""
outputs_file=""
stack_started=false

cleanup() {
    local status=$?

    trap - EXIT TERM
    set +o errexit
    for file in "${template_file}" "${outputs_file}"; do
        if [[ -n "${file}" ]]; then
            rm -f -- "${file}"
        fi
    done
    if [[ "${stack_started}" == true ]]; then
        aws --region "${region}" cloudformation describe-stack-events \
            --stack-name "${stack_name}" --output json \
            > "${ARTIFACT_DIR}/stack-events-${stack_name}.json" 2>/dev/null || true
    fi
    exit "${status}"
}

terminate() {
    exit 143
}

trap cleanup EXIT
trap terminate TERM

# Writes a SHARED_DIR file atomically so a consumer never reads a partial value.
publish() {
    local name=$1 value=$2 mode=${3:-0644} tmp

    tmp=$(mktemp "${SHARED_DIR}/.${name}.XXXXXX")
    chmod "${mode}" "${tmp}"
    printf '%s\n' "${value}" > "${tmp}"
    mv -f -- "${tmp}" "${SHARED_DIR}/${name}"
}

mkdir -p "${ARTIFACT_DIR}"

for command in aws base64 jq openssl sha256sum ssh; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the infra step image." >&2
        exit 1
    fi
done

for required_file in \
    "${CLUSTER_PROFILE_DIR}/.awscred" \
    "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
    "${SHARED_DIR}/public_subnet_ids" \
    "${SHARED_DIR}/private_subnet_ids" \
    "${SHARED_DIR}/vpc_id"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required infra input ${required_file} is missing or empty." >&2
        exit 1
    fi
done

for value in "${QUAY_STANDALONE_INSTANCE_TYPE}" "${QUAY_STANDALONE_REDIS_INSTANCE_TYPE}" \
    "${QUAY_STANDALONE_DB_INSTANCE_CLASS}" "${QUAY_STANDALONE_DB_ENGINE_VERSION}"; do
    if [[ ! "${value}" =~ ^[a-z0-9][a-z0-9.]*$ ]]; then
        echo "Invalid instance type, class or engine version: ${value}" >&2
        exit 1
    fi
done

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
vpc_id=$(<"${SHARED_DIR}/vpc_id")
# aws-provision-vpc-shared writes the subnet lists as ['subnet-a','subnet-b',...] in AZ order.
IFS=, read -r -a public_subnets <<< "$(tr -d "[]' " < "${SHARED_DIR}/public_subnet_ids")"
IFS=, read -r -a private_subnets <<< "$(tr -d "[]' " < "${SHARED_DIR}/private_subnet_ids")"

if [[ ! "${vpc_id}" =~ ^vpc-[a-f0-9]+$ ]] ||
   [[ "${#public_subnets[@]}" -ne 3 || "${#private_subnets[@]}" -ne 3 ]]; then
    echo "Expected a VPC with 3 public and 3 private subnets (ZONES_COUNT=3)." >&2
    exit 1
fi
for subnet in "${public_subnets[@]}" "${private_subnets[@]}"; do
    if [[ ! "${subnet}" =~ ^subnet-[a-f0-9]+$ ]]; then
        echo "Invalid subnet identifier ${subnet}." >&2
        exit 1
    fi
done
vpc_cidr=$(aws --region "${region}" ec2 describe-vpcs --vpc-ids "${vpc_id}" \
    --query 'Vpcs[0].CidrBlock' --output text)
if [[ ! "${vpc_cidr}" =~ ^[0-9.]+/[0-9]+$ ]]; then
    echo "Could not resolve the CIDR of ${vpc_id}." >&2
    exit 1
fi

ami_id=$(aws --region "${region}" ec2 describe-images \
    --owners 309956199498 \
    --filters \
        'Name=name,Values=RHEL-9.*_HVM-*-x86_64-*-Hourly2-GP3' \
        'Name=state,Values=available' \
        'Name=architecture,Values=x86_64' \
        'Name=root-device-type,Values=ebs' \
        'Name=virtualization-type,Values=hvm' \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' \
    --output text)
if [[ ! "${ami_id}" =~ ^ami-[a-f0-9]+$ ]]; then
    echo "Could not resolve an official RHEL 9 AMI in ${region}." >&2
    exit 1
fi
root_device_name=$(aws --region "${region}" ec2 describe-images \
    --image-ids "${ami_id}" --query 'Images[0].RootDeviceName' --output text)
if [[ ! "${root_device_name}" =~ ^/dev/[A-Za-z0-9]+$ ]]; then
    echo "Could not resolve the root device name for ${ami_id}." >&2
    exit 1
fi

public_key_base64=$(base64 -w 0 < "${CLUSTER_PROFILE_DIR}/ssh-publickey")
ssh_user_data="#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
install -d -m 0700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
printf '%s' '${public_key_base64}' | base64 --decode > /home/ec2-user/.ssh/authorized_keys
chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys
chmod 0600 /home/ec2-user/.ssh/authorized_keys
restorecon -RF /home/ec2-user/.ssh || true
"
redis_user_data=$(base64 -w 0 <<< "${ssh_user_data}")
quay_user_data=$(base64 -w 0 <<< "${ssh_user_data}dnf install -y curl jq openssl podman postgresql")

bucket="${stack_name,,}"
if (( ${#bucket} > 63 )); then
    bucket="qsha-$(printf '%s' "${bucket}" | sha256sum | cut -c1-40)"
fi
expiration_date=$(date -d '12 hours' --iso=minutes --utc)

# Publish the names before creating anything so post steps can find and check
# whatever exists even if this step fails; the job tag goes last because
# quay-standalone-aws-leak-check treats its presence as "infra started".
publish quay_standalone_region "${region}"
publish quay_standalone_stack_name "${stack_name}"
publish quay_standalone_db_identifier "${stack_name}"
publish quay_standalone_s3_bucket "${bucket}"
publish quay_standalone_ssh_user ec2-user
publish quay_standalone_job_tag "${job_tag}"

printf 's3://%s\n' "${bucket}" >> "${SHARED_DIR}/to_be_removed_s3_bucket_list"
create_bucket_args=()
if [[ "${region}" != us-east-1 ]]; then
    create_bucket_args=(--create-bucket-configuration "LocationConstraint=${region}")
fi
aws --region "${region}" s3api create-bucket --bucket "${bucket}" "${create_bucket_args[@]}" >/dev/null
aws --region "${region}" s3api put-public-access-block --bucket "${bucket}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws --region "${region}" s3api put-bucket-tagging --bucket "${bucket}" \
    --tagging "$(jq -cn --arg job "${job_tag}" --arg exp "${expiration_date}" \
        '{TagSet: [{Key: "quay-standalone-job", Value: $job}, {Key: "expirationDate", Value: $exp}]}')"

template_file=$(mktemp /tmp/quay-standalone-aws-infra.XXXXXX.yaml)
cat > "${template_file}" <<'EOF'
AWSTemplateFormatVersion: 2010-09-09
Description: Quay standalone HA nodes, Redis host, Multi-AZ RDS PostgreSQL, NLB and internal Clair NLB
Parameters:
  AmiId:
    Type: AWS::EC2::Image::Id
  RootDeviceName:
    Type: String
  VpcId:
    Type: AWS::EC2::VPC::Id
  VpcCidr:
    Type: String
  PublicSubnet1:
    Type: AWS::EC2::Subnet::Id
  PublicSubnet2:
    Type: AWS::EC2::Subnet::Id
  PublicSubnet3:
    Type: AWS::EC2::Subnet::Id
  PrivateSubnet1:
    Type: AWS::EC2::Subnet::Id
  PrivateSubnet2:
    Type: AWS::EC2::Subnet::Id
  PrivateSubnet3:
    Type: AWS::EC2::Subnet::Id
  QuayInstanceType:
    Type: String
  QuayUserData:
    Type: String
  RedisInstanceType:
    Type: String
  RedisUserData:
    Type: String
  DbIdentifier:
    Type: String
  DbEngineVersion:
    Type: String
  DbInstanceClass:
    Type: String
  DbName:
    Type: String
  DbUser:
    Type: String
  DbPassword:
    Type: String
    NoEcho: true
Resources:
  QuaySecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Quay standalone nodes
      VpcId: !Ref VpcId
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      # NLB instance targets see the client IP, so 8443 must be open to clients
      # as well as to the NLB health checks.
      - IpProtocol: tcp
        FromPort: 8443
        ToPort: 8443
        CidrIp: 0.0.0.0/0
      # Clair API and introspection, for the internal NLB and its health checks.
      - IpProtocol: tcp
        FromPort: 8081
        ToPort: 8081
        CidrIp: !Ref VpcCidr
      - IpProtocol: tcp
        FromPort: 8089
        ToPort: 8089
        CidrIp: !Ref VpcCidr
  RedisSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Quay standalone Redis host
      VpcId: !Ref VpcId
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 6379
        ToPort: 6379
        SourceSecurityGroupId: !GetAtt QuaySecurityGroup.GroupId
  DbSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Quay standalone PostgreSQL
      VpcId: !Ref VpcId
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 5432
        ToPort: 5432
        SourceSecurityGroupId: !GetAtt QuaySecurityGroup.GroupId
  Quay1:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      InstanceType: !Ref QuayInstanceType
      UserData: !Ref QuayUserData
      NetworkInterfaces:
      - AssociatePublicIpAddress: true
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt QuaySecurityGroup.GroupId
        SubnetId: !Ref PublicSubnet1
      BlockDeviceMappings:
      - DeviceName: !Ref RootDeviceName
        Ebs:
          DeleteOnTermination: true
          Encrypted: true
          VolumeSize: 30
          VolumeType: gp3
      Tags:
      - Key: Name
        Value: !Sub "${AWS::StackName}-quay-1"
  Quay2:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      InstanceType: !Ref QuayInstanceType
      UserData: !Ref QuayUserData
      NetworkInterfaces:
      - AssociatePublicIpAddress: true
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt QuaySecurityGroup.GroupId
        SubnetId: !Ref PublicSubnet2
      BlockDeviceMappings:
      - DeviceName: !Ref RootDeviceName
        Ebs:
          DeleteOnTermination: true
          Encrypted: true
          VolumeSize: 30
          VolumeType: gp3
      Tags:
      - Key: Name
        Value: !Sub "${AWS::StackName}-quay-2"
  Quay3:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      InstanceType: !Ref QuayInstanceType
      UserData: !Ref QuayUserData
      NetworkInterfaces:
      - AssociatePublicIpAddress: true
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt QuaySecurityGroup.GroupId
        SubnetId: !Ref PublicSubnet3
      BlockDeviceMappings:
      - DeviceName: !Ref RootDeviceName
        Ebs:
          DeleteOnTermination: true
          Encrypted: true
          VolumeSize: 30
          VolumeType: gp3
      Tags:
      - Key: Name
        Value: !Sub "${AWS::StackName}-quay-3"
  Redis:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      InstanceType: !Ref RedisInstanceType
      UserData: !Ref RedisUserData
      NetworkInterfaces:
      - AssociatePublicIpAddress: true
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt RedisSecurityGroup.GroupId
        SubnetId: !Ref PublicSubnet1
      BlockDeviceMappings:
      - DeviceName: !Ref RootDeviceName
        Ebs:
          DeleteOnTermination: true
          Encrypted: true
          VolumeType: gp3
      Tags:
      - Key: Name
        Value: !Sub "${AWS::StackName}-redis"
  DbSubnetGroup:
    Type: AWS::RDS::DBSubnetGroup
    Properties:
      DBSubnetGroupDescription: Quay standalone private subnets
      SubnetIds:
      - !Ref PrivateSubnet1
      - !Ref PrivateSubnet2
      - !Ref PrivateSubnet3
  Db:
    Type: AWS::RDS::DBInstance
    # The DBInstance default is Snapshot, which would outlive the job.
    DeletionPolicy: Delete
    UpdateReplacePolicy: Delete
    Properties:
      DBInstanceIdentifier: !Ref DbIdentifier
      Engine: postgres
      EngineVersion: !Ref DbEngineVersion
      DBInstanceClass: !Ref DbInstanceClass
      AllocatedStorage: "20"
      StorageType: gp3
      StorageEncrypted: true
      MultiAZ: true
      PubliclyAccessible: false
      DeletionProtection: false
      BackupRetentionPeriod: 0
      DeleteAutomatedBackups: true
      DBName: !Ref DbName
      MasterUsername: !Ref DbUser
      MasterUserPassword: !Ref DbPassword
      DBSubnetGroupName: !Ref DbSubnetGroup
      VPCSecurityGroups:
      - !GetAtt DbSecurityGroup.GroupId
  LoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Type: network
      Scheme: internet-facing
      Subnets:
      - !Ref PublicSubnet1
      - !Ref PublicSubnet2
      - !Ref PublicSubnet3
      # One node per AZ: without cross-zone, a stopped node blackholes its AZ's
      # NLB address until DNS failover catches up.
      LoadBalancerAttributes:
      - Key: load_balancing.cross_zone.enabled
        Value: "true"
  TargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      VpcId: !Ref VpcId
      Protocol: TCP
      Port: 8443
      TargetType: instance
      HealthCheckProtocol: HTTPS
      HealthCheckPath: /health/instance
      HealthCheckIntervalSeconds: 10
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 2
      Targets:
      - Id: !Ref Quay1
      - Id: !Ref Quay2
      - Id: !Ref Quay3
  Listener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref LoadBalancer
      Protocol: TCP
      Port: 443
      DefaultActions:
      - Type: forward
        TargetGroupArn: !Ref TargetGroup
  ClairLoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Type: network
      Scheme: internal
      Subnets:
      - !Ref PublicSubnet1
      - !Ref PublicSubnet2
      - !Ref PublicSubnet3
      # Clair runs in AZs 1 and 2 only, so AZ 3's address needs cross-zone, and
      # so does an AZ whose scanner failover stopped.
      LoadBalancerAttributes:
      - Key: load_balancing.cross_zone.enabled
        Value: "true"
  ClairTargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      VpcId: !Ref VpcId
      Protocol: TCP
      Port: 8081
      TargetType: instance
      # Quay nodes 1 and 2 are also targets: with the client IP preserved, a
      # target calling its own NLB hairpins and times out.
      TargetGroupAttributes:
      - Key: preserve_client_ip.enabled
        Value: "false"
      # /readyz turns 200 once migrations are done; /healthz is 200 from start.
      HealthCheckProtocol: HTTP
      HealthCheckPort: "8089"
      HealthCheckPath: /readyz
      HealthCheckIntervalSeconds: 10
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 2
      Targets:
      - Id: !Ref Quay1
      - Id: !Ref Quay2
  ClairListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref ClairLoadBalancer
      Protocol: TCP
      Port: 8081
      DefaultActions:
      - Type: forward
        TargetGroupArn: !Ref ClairTargetGroup
Outputs:
  Hostname:
    Value: !GetAtt LoadBalancer.DNSName
  TargetGroupArn:
    Value: !Ref TargetGroup
  ClairHostname:
    Value: !GetAtt ClairLoadBalancer.DNSName
  ClairTargetGroupArn:
    Value: !Ref ClairTargetGroup
  Quay1InstanceId:
    Value: !Ref Quay1
  Quay1PublicIp:
    Value: !GetAtt Quay1.PublicIp
  Quay1PrivateIp:
    Value: !GetAtt Quay1.PrivateIp
  Quay2InstanceId:
    Value: !Ref Quay2
  Quay2PublicIp:
    Value: !GetAtt Quay2.PublicIp
  Quay2PrivateIp:
    Value: !GetAtt Quay2.PrivateIp
  Quay3InstanceId:
    Value: !Ref Quay3
  Quay3PublicIp:
    Value: !GetAtt Quay3.PublicIp
  Quay3PrivateIp:
    Value: !GetAtt Quay3.PrivateIp
  RedisInstanceId:
    Value: !Ref Redis
  RedisPublicIp:
    Value: !GetAtt Redis.PublicIp
  RedisPrivateIp:
    Value: !GetAtt Redis.PrivateIp
  DbEndpoint:
    Value: !GetAtt Db.Endpoint.Address
  DbPort:
    Value: !GetAtt Db.Endpoint.Port
  DbName:
    Value: !Ref DbName
  DbUser:
    Value: !Ref DbUser
  DbIdentifier:
    Value: !Ref Db
EOF

# Disable tracing while the DB password is in scope.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
db_password=$(openssl rand -hex 24)
printf '%s\n' "${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
stack_started=true
aws --region "${region}" cloudformation create-stack \
    --stack-name "${stack_name}" \
    --template-body "file://${template_file}" \
    --tags "Key=expirationDate,Value=${expiration_date}" "Key=quay-standalone-job,Value=${job_tag}" \
    --parameters \
        "ParameterKey=AmiId,ParameterValue=${ami_id}" \
        "ParameterKey=RootDeviceName,ParameterValue=${root_device_name}" \
        "ParameterKey=VpcId,ParameterValue=${vpc_id}" \
        "ParameterKey=VpcCidr,ParameterValue=${vpc_cidr}" \
        "ParameterKey=PublicSubnet1,ParameterValue=${public_subnets[0]}" \
        "ParameterKey=PublicSubnet2,ParameterValue=${public_subnets[1]}" \
        "ParameterKey=PublicSubnet3,ParameterValue=${public_subnets[2]}" \
        "ParameterKey=PrivateSubnet1,ParameterValue=${private_subnets[0]}" \
        "ParameterKey=PrivateSubnet2,ParameterValue=${private_subnets[1]}" \
        "ParameterKey=PrivateSubnet3,ParameterValue=${private_subnets[2]}" \
        "ParameterKey=QuayInstanceType,ParameterValue=${QUAY_STANDALONE_INSTANCE_TYPE}" \
        "ParameterKey=QuayUserData,ParameterValue=${quay_user_data}" \
        "ParameterKey=RedisInstanceType,ParameterValue=${QUAY_STANDALONE_REDIS_INSTANCE_TYPE}" \
        "ParameterKey=RedisUserData,ParameterValue=${redis_user_data}" \
        "ParameterKey=DbIdentifier,ParameterValue=${stack_name}" \
        "ParameterKey=DbEngineVersion,ParameterValue=${QUAY_STANDALONE_DB_ENGINE_VERSION}" \
        "ParameterKey=DbInstanceClass,ParameterValue=${QUAY_STANDALONE_DB_INSTANCE_CLASS}" \
        "ParameterKey=DbName,ParameterValue=${db_name}" \
        "ParameterKey=DbUser,ParameterValue=${db_user}" \
        "ParameterKey=DbPassword,ParameterValue=${db_password}" \
    >/dev/null
publish quay_standalone_db_password "${db_password}" 0600
unset db_password
$WAS_TRACING && set -x

echo "Waiting for stack ${stack_name}; Multi-AZ RDS usually takes 20-40 minutes."
aws --region "${region}" cloudformation wait stack-create-complete --stack-name "${stack_name}"

outputs_file=$(mktemp /tmp/quay-standalone-aws-infra-outputs.XXXXXX.json)
aws --region "${region}" cloudformation describe-stacks --stack-name "${stack_name}" \
    --query 'Stacks[0].Outputs' --output json > "${outputs_file}"
output() {
    jq -er --arg key "$1" '.[] | select(.OutputKey == $key) | .OutputValue' "${outputs_file}"
}

nodes=()
instance_ids=()
for host in Quay1 Quay2 Quay3 Redis; do
    instance_id=$(output "${host}InstanceId")
    public_ip=$(output "${host}PublicIp")
    private_ip=$(output "${host}PrivateIp")
    if [[ ! "${instance_id}" =~ ^i-[a-f0-9]+$ ]] ||
       [[ ! "${public_ip}" =~ ^[0-9.]+$ ]] ||
       [[ ! "${private_ip}" =~ ^[0-9.]+$ ]]; then
        echo "Stack ${stack_name} returned invalid details for ${host}." >&2
        exit 1
    fi
    nodes+=("${instance_id} ${public_ip} ${private_ip}")
    instance_ids+=("${instance_id}")
done

declare -A shared_outputs=(
    [quay_standalone_hostname]=Hostname
    [quay_standalone_target_group_arn]=TargetGroupArn
    [quay_standalone_clair_hostname]=ClairHostname
    [quay_standalone_clair_target_group_arn]=ClairTargetGroupArn
    [quay_standalone_db_endpoint]=DbEndpoint
    [quay_standalone_db_port]=DbPort
    [quay_standalone_db_name]=DbName
    [quay_standalone_db_user]=DbUser
    [quay_standalone_db_identifier]=DbIdentifier
)
for name in "${!shared_outputs[@]}"; do
    value=$(output "${shared_outputs[${name}]}")
    publish "${name}" "${value}"
done
publish quay_standalone_clair_endpoint "http://$(output ClairHostname):8081"
publish quay_standalone_nodes "$(printf '%s\n' "${nodes[@]:0:3}")"
publish quay_standalone_redis "${nodes[3]}"

aws --region "${region}" ec2 wait instance-status-ok --instance-ids "${instance_ids[@]}"

if ! whoami >/dev/null 2>&1; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writable and the current UID has no passwd entry." >&2
        exit 1
    fi
fi

ssh_options=(
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o "IdentityFile=${CLUSTER_PROFILE_DIR}/ssh-privatekey"
    -o ConnectTimeout=10
    -o ConnectionAttempts=3
)
for node in "${nodes[@]}"; do
    read -r instance_id public_ip _ <<< "${node}"
    ssh_ready=false
    for attempt in $(seq 1 30); do
        if ssh "${ssh_options[@]}" "ec2-user@${public_ip}" true >/dev/null 2>&1; then
            ssh_ready=true
            break
        fi
        echo "Waiting for SSH on ${instance_id} (${attempt}/30)."
        sleep 10
    done
    if [[ "${ssh_ready}" != true ]]; then
        echo "Instance ${instance_id} did not become reachable over SSH." >&2
        exit 1
    fi
    ssh "${ssh_options[@]}" "ec2-user@${public_ip}" "sudo cloud-init status --wait"
done
for node in "${nodes[@]:0:3}"; do
    read -r instance_id public_ip _ <<< "${node}"
    ssh "${ssh_options[@]}" "ec2-user@${public_ip}" "podman --version && psql --version"
done

echo "Quay standalone HA infrastructure ${stack_name} is ready."
