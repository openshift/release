#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
stack_name="${NAMESPACE}-${UNIQUE_HASH}-omr2"
template_file=""
stack_started=false
published=false
declare -a output_files=(
    "${SHARED_DIR}/omr_host_public_address"
    "${SHARED_DIR}/omr_host_private_address"
    "${SHARED_DIR}/omr_host_ssh_user"
    "${SHARED_DIR}/omr_host_instance_id"
)

cleanup() {
    local status=$?

    trap - EXIT TERM
    set +o errexit
    if [[ "${status}" -eq 0 ]]; then
        EXIT_CODE=0
    fi
    printf '%s\n' "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"

    if [[ "${published}" != true ]]; then
        rm -f -- "${output_files[@]}"
    fi
    if [[ -n "${template_file}" ]]; then
        rm -f -- "${template_file}"
    fi
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

mkdir -p "${ARTIFACT_DIR}"
rm -f -- "${output_files[@]}"

for command in aws base64 ssh yq-go; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the host provision step image." >&2
        exit 1
    fi
done

for required_file in \
    "${CLUSTER_PROFILE_DIR}/.awscred" \
    "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
    "${SHARED_DIR}/public_subnet_ids" \
    "${SHARED_DIR}/vpc_id"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required host provision input ${required_file} is missing or empty." >&2
        exit 1
    fi
done

if [[ ! "${OMR_V2_INSTANCE_TYPE}" =~ ^[a-z0-9][a-z0-9.]*$ ]]; then
    echo "OMR_V2_INSTANCE_TYPE is invalid." >&2
    exit 1
fi
if [[ ! "${OMR_V2_ROOT_VOLUME_SIZE}" =~ ^[0-9]+$ ]] ||
   (( OMR_V2_ROOT_VOLUME_SIZE < 100 || OMR_V2_ROOT_VOLUME_SIZE > 16384 )); then
    echo "OMR_V2_ROOT_VOLUME_SIZE must be between 100 and 16384 GiB." >&2
    exit 1
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
region="${REGION:-$LEASED_RESOURCE}"
vpc_id=$(<"${SHARED_DIR}/vpc_id")
public_subnet=$(yq-go r "${SHARED_DIR}/public_subnet_ids" '[0]')

if [[ ! "${vpc_id}" =~ ^vpc-[a-f0-9]+$ ]] ||
   [[ ! "${public_subnet}" =~ ^subnet-[a-f0-9]+$ ]]; then
    echo "The disconnected VPC or public subnet identifier is invalid." >&2
    exit 1
fi

vpc_cidr=$(aws --region "${region}" ec2 describe-vpcs \
    --vpc-ids "${vpc_id}" --query 'Vpcs[0].CidrBlock' --output text)
if [[ -z "${vpc_cidr}" || "${vpc_cidr}" == "None" ]]; then
    echo "Could not resolve the disconnected VPC CIDR." >&2
    exit 1
fi

ami_id="${OMR_V2_AMI_ID}"
if [[ -z "${ami_id}" ]]; then
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
fi
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
if [[ -z "${public_key_base64}" ]]; then
    echo "The encoded SSH public key is empty." >&2
    exit 1
fi

template_file=$(mktemp /tmp/quay-omr-v2-host.XXXXXX.yaml)
cat > "${template_file}" <<'EOF'
AWSTemplateFormatVersion: 2010-09-09
Description: Dedicated RHEL host for OMR v2 to v3 migration testing
Parameters:
  AmiId:
    Type: AWS::EC2::Image::Id
  InstanceType:
    Type: String
  PublicKeyBase64:
    Type: String
  PublicSubnet:
    Type: AWS::EC2::Subnet::Id
  RootVolumeSize:
    Type: Number
  RootDeviceName:
    Type: String
  VpcCidr:
    Type: String
  VpcId:
    Type: AWS::EC2::VPC::Id
Resources:
  OMRSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Dedicated OMR migration host security group
      VpcId: !Ref VpcId
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      - IpProtocol: tcp
        FromPort: 8443
        ToPort: 8443
        CidrIp: !Ref VpcCidr
  OMRHost:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      InstanceType: !Ref InstanceType
      NetworkInterfaces:
      - AssociatePublicIpAddress: true
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt OMRSecurityGroup.GroupId
        SubnetId: !Ref PublicSubnet
      BlockDeviceMappings:
      - DeviceName: !Ref RootDeviceName
        Ebs:
          DeleteOnTermination: true
          Encrypted: true
          VolumeSize: !Ref RootVolumeSize
          VolumeType: gp3
      Tags:
      - Key: Name
        Value: !Sub "${AWS::StackName}-host"
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash
          set -o nounset
          set -o errexit
          set -o pipefail
          install -d -m 0700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
          # OMR appends a generated local-install key, so preserve the line boundary.
          authorized_key=$(printf '%s' '${PublicKeyBase64}' | base64 --decode)
          printf '%s\n' "$authorized_key" > /home/ec2-user/.ssh/authorized_keys
          unset authorized_key
          chown ec2-user:ec2-user /home/ec2-user/.ssh/authorized_keys
          chmod 0600 /home/ec2-user/.ssh/authorized_keys
          restorecon -RF /home/ec2-user/.ssh || true
          dnf install -y curl gzip openssl podman slirp4netns tar
          install -d -m 0700 -o ec2-user -g ec2-user \
            /home/ec2-user/.config \
            /home/ec2-user/.config/containers
          printf '[network]\ndefault_rootless_network_cmd = "slirp4netns"\n' > /home/ec2-user/.config/containers/containers.conf
          chown ec2-user:ec2-user /home/ec2-user/.config/containers/containers.conf
Outputs:
  InstanceId:
    Value: !Ref OMRHost
  PrivateDnsName:
    Value: !GetAtt OMRHost.PrivateDnsName
  PublicIp:
    Value: !GetAtt OMRHost.PublicIp
EOF

expiration_date=$(date -d '12 hours' --iso=minutes --utc)
printf '%s\n' "${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"
stack_started=true
aws --region "${region}" cloudformation create-stack \
    --stack-name "${stack_name}" \
    --template-body "file://${template_file}" \
    --tags "Key=expirationDate,Value=${expiration_date}" \
    --parameters \
        "ParameterKey=AmiId,ParameterValue=${ami_id}" \
        "ParameterKey=InstanceType,ParameterValue=${OMR_V2_INSTANCE_TYPE}" \
        "ParameterKey=PublicKeyBase64,ParameterValue=${public_key_base64}" \
        "ParameterKey=PublicSubnet,ParameterValue=${public_subnet}" \
        "ParameterKey=RootDeviceName,ParameterValue=${root_device_name}" \
        "ParameterKey=RootVolumeSize,ParameterValue=${OMR_V2_ROOT_VOLUME_SIZE}" \
        "ParameterKey=VpcCidr,ParameterValue=${vpc_cidr}" \
        "ParameterKey=VpcId,ParameterValue=${vpc_id}"
aws --region "${region}" cloudformation wait stack-create-complete \
    --stack-name "${stack_name}"

instance_id=$(aws --region "${region}" cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    --query 'Stacks[0].Outputs[?OutputKey == `InstanceId`].OutputValue | [0]' \
    --output text)
private_address=$(aws --region "${region}" cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    --query 'Stacks[0].Outputs[?OutputKey == `PrivateDnsName`].OutputValue | [0]' \
    --output text)
public_address=$(aws --region "${region}" cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    --query 'Stacks[0].Outputs[?OutputKey == `PublicIp`].OutputValue | [0]' \
    --output text)

if [[ ! "${instance_id}" =~ ^i-[a-f0-9]+$ ]] ||
   [[ ! "${private_address}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
   [[ ! "${public_address}" =~ ^[0-9.]+$ ]]; then
    echo "The dedicated OMR host stack returned invalid connection details." >&2
    exit 1
fi

printf '%s\n' "${instance_id}" >> "${SHARED_DIR}/aws-instance-ids.txt"

# Retain connection and instance identity if later bootstrap validation fails so
# the unconditional post step can still collect AWS and SSH diagnostics.
public_tmp=$(mktemp "${SHARED_DIR}/.omr_host_public_address.XXXXXX")
private_tmp=$(mktemp "${SHARED_DIR}/.omr_host_private_address.XXXXXX")
user_tmp=$(mktemp "${SHARED_DIR}/.omr_host_ssh_user.XXXXXX")
instance_tmp=$(mktemp "${SHARED_DIR}/.omr_host_instance_id.XXXXXX")
printf '%s\n' "${public_address}" > "${public_tmp}"
printf '%s\n' "${private_address}" > "${private_tmp}"
printf '%s\n' ec2-user > "${user_tmp}"
printf '%s\n' "${instance_id}" > "${instance_tmp}"
chmod 0644 "${public_tmp}" "${private_tmp}" "${user_tmp}" "${instance_tmp}"
mv -f -- "${public_tmp}" "${SHARED_DIR}/omr_host_public_address"
mv -f -- "${private_tmp}" "${SHARED_DIR}/omr_host_private_address"
mv -f -- "${user_tmp}" "${SHARED_DIR}/omr_host_ssh_user"
mv -f -- "${instance_tmp}" "${SHARED_DIR}/omr_host_instance_id"
published=true

aws --region "${region}" ec2 wait instance-status-ok --instance-ids "${instance_id}"

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
ssh_ready=false
for attempt in $(seq 1 30); do
    if ssh "${ssh_options[@]}" "ec2-user@${public_address}" true >/dev/null 2>&1; then
        ssh_ready=true
        break
    fi
    echo "Waiting for dedicated OMR host SSH (${attempt}/30)."
    sleep 10
done
if [[ "${ssh_ready}" != true ]]; then
    echo "The dedicated OMR host did not become reachable over SSH." >&2
    exit 1
fi

ssh "${ssh_options[@]}" "ec2-user@${public_address}" \
    "sudo cloud-init status --wait && podman system migrate && podman --version && openssl version && command -v slirp4netns"

echo "Dedicated RHEL 9 OMR host ${instance_id} is ready."
