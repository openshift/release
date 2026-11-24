#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Provision an EC2 host prepared for running kit clusters and tests:
#   - Ubuntu 24.04 LTS with rootless Podman for the "ubuntu" user
#   - the rootless Podman API socket enabled and active
#   - the kit CLI installed from a GitHub release, digest-verified
#   - kubectl installed
# The instance is created through CloudFormation and registered in
# ${SHARED_DIR}/to_be_removed_cf_stack_list so the standard
# aws-deprovision-stacks post step tears it down.

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${REGION:-$LEASED_RESOURCE}"
JOB_NAME="${NAMESPACE}-${UNIQUE_HASH}"
stack_name="${JOB_NAME}"
ssh_user="ubuntu"

ubuntu_series="24.04"

template_file=""
remote_setup_script=""
stack_started=false
host_address=""
ssh_reachable=false

function log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

function cleanup() {
  local status=$?

  trap - EXIT TERM
  set +o errexit
  if [[ "${stack_started}" == true ]]; then
    aws --region "${REGION}" cloudformation describe-stack-events \
      --stack-name "${stack_name}" --output json \
      > "${ARTIFACT_DIR}/stack-events-${stack_name}.json" 2>/dev/null
  fi
  if [[ "${status}" -ne 0 && "${ssh_reachable}" == true ]]; then
    ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" \
      "cat /tmp/kit-host-setup.log" \
      > "${ARTIFACT_DIR}/kit-host-setup.log" 2>/dev/null
    ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" \
      "sudo cat /var/log/cloud-init-output.log" \
      > "${ARTIFACT_DIR}/cloud-init-output.log" 2>/dev/null
  fi
  if [[ -n "${template_file}" ]]; then
    rm -f -- "${template_file}"
  fi
  if [[ -n "${remote_setup_script}" ]]; then
    rm -f -- "${remote_setup_script}"
  fi
  exit "${status}"
}

function terminate() {
  # Exit through the EXIT trap so artifacts are still collected.
  exit 143
}

trap cleanup EXIT
trap terminate TERM

mkdir -p "${ARTIFACT_DIR}"

# ---------------------------------------------------------------- preflight

for command in aws jq ssh base64 curl; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "Required command ${command} is unavailable in the provision step image." >&2
    exit 1
  fi
done

for required_file in \
  "${CLUSTER_PROFILE_DIR}/.awscred" \
  "${CLUSTER_PROFILE_DIR}/ssh-publickey" \
  "${CLUSTER_PROFILE_DIR}/ssh-privatekey"; do
  if [[ ! -s "${required_file}" ]]; then
    echo "Required provision input ${required_file} is missing or empty." >&2
    exit 1
  fi
done

case "${EC2_ARCH}" in
  x86_64) asset_arch="amd64" ;;
  arm64) asset_arch="arm64" ;;
  *)
    echo "EC2_ARCH must be x86_64 or arm64, got '${EC2_ARCH}'." >&2
    exit 1
    ;;
esac

if [[ ! "${EC2_INSTANCE_TYPE}" =~ ^[a-z0-9][a-z0-9.]*$ ]]; then
  echo "EC2_INSTANCE_TYPE is invalid: '${EC2_INSTANCE_TYPE}'." >&2
  exit 1
fi

if [[ ! "${EC2_ROOT_VOLUME_SIZE}" =~ ^[0-9]+$ ]] ||
  (( EC2_ROOT_VOLUME_SIZE < 20 || EC2_ROOT_VOLUME_SIZE > 16384 )); then
  echo "EC2_ROOT_VOLUME_SIZE must be between 20 and 16384 GiB." >&2
  exit 1
fi

if [[ -z "${KIT_VERSION}" ]]; then
  echo "KIT_VERSION must not be empty." >&2
  exit 1
fi

# ------------------------------------------------------------ AMI resolution

# The Ubuntu AMI is discovered through the EC2 API instead of the public
# SSM parameters because the CI robot users of the cluster profiles are
# not granted ssm:GetParameters.
ubuntu_codename="noble"
canonical_owner="099720109477"

if [[ -n "${EC2_AMI}" ]]; then
  ami_id="${EC2_AMI}"
  log "Using explicit AMI ${ami_id}"
else
  ami_id=$(aws --region "${REGION}" ec2 describe-images \
    --owners "${canonical_owner}" \
    --filters \
    "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-${ubuntu_codename}-${ubuntu_series}-${asset_arch}-server-*" \
    "Name=state,Values=available" \
    "Name=architecture,Values=${EC2_ARCH}" \
    "Name=root-device-type,Values=ebs" \
    "Name=virtualization-type,Values=hvm" \
    --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' \
    --output text)
  if [[ ! "${ami_id}" =~ ^ami-[a-f0-9]+$ ]]; then
    echo "Could not resolve the newest Ubuntu ${ubuntu_series} (${ubuntu_codename}) ${EC2_ARCH} AMI in ${REGION} from owner ${canonical_owner}." >&2
    exit 1
  fi
  log "Resolved Ubuntu ${ubuntu_series} ${EC2_ARCH} AMI ${ami_id} in ${REGION}"
fi

root_device_name=$(aws --region "${REGION}" ec2 describe-images \
  --image-ids "${ami_id}" \
  --query 'Images[0].RootDeviceName' --output text)
if [[ ! "${root_device_name}" =~ ^/dev/[A-Za-z0-9]+$ ]]; then
  echo "Could not resolve the root device name of AMI ${ami_id}." >&2
  exit 1
fi

# ------------------------------------------------------- placement and stack

availability_zone=$(aws --region "${REGION}" ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=${EC2_INSTANCE_TYPE}" \
  --query 'InstanceTypeOfferings[0].Location' --output text)
if [[ -z "${availability_zone}" || "${availability_zone}" == "None" ]]; then
  echo "The instance type ${EC2_INSTANCE_TYPE} is not offered in ${REGION}." >&2
  exit 1
fi
log "Placing the kit host in availability zone ${availability_zone}"

public_key_base64=$(base64 -w 0 < "${CLUSTER_PROFILE_DIR}/ssh-publickey")
if [[ -z "${public_key_base64}" ]]; then
  echo "The encoded SSH public key is empty." >&2
  exit 1
fi

template_file=$(mktemp /tmp/kit-infra-aws-ec2.XXXXXX.yaml)
cat > "${template_file}" <<'EOF'
AWSTemplateFormatVersion: 2010-09-09
Description: Standalone EC2 host for kit (Kubernetes Integration Testing)
Parameters:
  AmiId:
    Type: AWS::EC2::Image::Id
  InstanceType:
    Type: String
  RootDeviceName:
    Type: String
  RootVolumeSize:
    Type: Number
  PublicKeyBase64:
    Type: String
  AvailabilityZone:
    Type: String
Resources:
  VPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.192.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
  InternetGateway:
    Type: AWS::EC2::InternetGateway
  GatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref VPC
      InternetGatewayId: !Ref InternetGateway
  PublicSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      AvailabilityZone: !Ref AvailabilityZone
      CidrBlock: 10.192.10.0/24
      MapPublicIpOnLaunch: true
      VpcId: !Ref VPC
  RouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref VPC
  PublicRoute:
    Type: AWS::EC2::Route
    DependsOn: GatewayAttachment
    Properties:
      RouteTableId: !Ref RouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway
  SubnetRouteTableAssociation:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      RouteTableId: !Ref RouteTable
      SubnetId: !Ref PublicSubnet
  HostSecurityGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: kit host, SSH access from CI
      SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 22
        ToPort: 22
        CidrIp: 0.0.0.0/0
      VpcId: !Ref VPC
  Host:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Ref AmiId
      InstanceType: !Ref InstanceType
      MetadataOptions:
        HttpTokens: required
        HttpPutResponseHopLimit: 1
      BlockDeviceMappings:
      - DeviceName: !Ref RootDeviceName
        Ebs:
          DeleteOnTermination: true
          Encrypted: true
          VolumeSize: !Ref RootVolumeSize
          VolumeType: gp3
      NetworkInterfaces:
      - AssociatePublicIpAddress: true
        DeviceIndex: "0"
        GroupSet:
        - !GetAtt HostSecurityGroup.GroupId
        SubnetId: !Ref PublicSubnet
      Tags:
      - Key: Name
        Value: !Sub "${AWS::StackName}-kit-host"
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash
          set -o nounset
          set -o errexit
          set -o pipefail
          install -d -m 0700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
          authorized_key=$(printf '%s' '${PublicKeyBase64}' | base64 --decode)
          printf '%s\n' "$authorized_key" > /home/ubuntu/.ssh/authorized_keys
          unset authorized_key
          chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
          chmod 0600 /home/ubuntu/.ssh/authorized_keys
Outputs:
  InstanceId:
    Value: !Ref Host
  PublicIp:
    Value: !GetAtt Host.PublicIp
EOF

stack_status=$(aws --region "${REGION}" cloudformation describe-stacks \
  --stack-name "${stack_name}" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)
if [[ -n "${stack_status}" && "${stack_status}" != "None" ]]; then
  log "Stack ${stack_name} already exists (status: ${stack_status}), deleting it first"
  aws --region "${REGION}" cloudformation delete-stack --stack-name "${stack_name}"
  aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${stack_name}"
fi

# Register the stack for the aws-deprovision-stacks post step before creating
# it, so the stack is cleaned up even when its creation or setup fails.
expiration_date=$(date -d '12 hours' --iso=minutes --utc)
printf '%s\n' "${stack_name}" >> "${SHARED_DIR}/to_be_removed_cf_stack_list"

log "Creating stack ${stack_name}"
stack_started=true
aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${stack_name}" \
  --template-body "file://${template_file}" \
  --tags "Key=expirationDate,Value=${expiration_date}" \
  --parameters \
  "ParameterKey=AmiId,ParameterValue=${ami_id}" \
  "ParameterKey=InstanceType,ParameterValue=${EC2_INSTANCE_TYPE}" \
  "ParameterKey=RootDeviceName,ParameterValue=${root_device_name}" \
  "ParameterKey=RootVolumeSize,ParameterValue=${EC2_ROOT_VOLUME_SIZE}" \
  "ParameterKey=PublicKeyBase64,ParameterValue=${public_key_base64}" \
  "ParameterKey=AvailabilityZone,ParameterValue=${availability_zone}"

if ! aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}"; then
  echo "Stack ${stack_name} creation failed. Stack details and events:" >&2
  aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" \
    --query 'Stacks[0].[StackStatus,StackStatusReason]' --output table || true
  aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${stack_name}" \
    --query 'StackEvents[0:40].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
    --output table || true
  exit 1
fi

instance_id=$(aws --region "${REGION}" cloudformation describe-stacks \
  --stack-name "${stack_name}" \
  --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
host_address=$(aws --region "${REGION}" cloudformation describe-stacks \
  --stack-name "${stack_name}" \
  --query 'Stacks[0].Outputs[?OutputKey==`PublicIp`].OutputValue' --output text)

if [[ ! "${instance_id}" =~ ^i-[a-f0-9]+$ ]] ||
  [[ ! "${host_address}" =~ ^[0-9.]+$ ]]; then
  echo "Stack ${stack_name} returned invalid connection details (instance ${instance_id}, address ${host_address})." >&2
  exit 1
fi
log "Kit host instance ${instance_id} at ${host_address}"

# ------------------------------------------------------------ host readiness

SSHOPTS=(-o 'ConnectTimeout=10'
  -o 'ConnectionAttempts=3'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

printf '%s\n' "${host_address}" > "${SHARED_DIR}/public_address"
printf '%s\n' "${ssh_user}" > "${SHARED_DIR}/ssh_user"

log "Waiting for instance ${instance_id} status checks"
aws --region "${REGION}" ec2 wait instance-status-ok --instance-ids "${instance_id}"

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is
# required to be able to SSH.
if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "/etc/passwd is not writable and the current UID has no passwd entry." >&2
    exit 1
  fi
fi

ssh_ready=false
for attempt in $(seq 1 60); do
  if ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" true >/dev/null 2>&1; then
    ssh_ready=true
    break
  fi
  echo "Waiting for kit host SSH (${attempt}/60)."
  sleep 10
done
if [[ "${ssh_ready}" != true ]]; then
  echo "The kit host did not become reachable over SSH." >&2
  exit 1
fi
ssh_reachable=true
log "SSH connection to the kit host established"

# ------------------------------------------------------------- host setup

# The setup runs on the host itself so that every action and its output are
# visible in the step log. kit is downloaded on the host because its fresh
# public IP is not affected by GitHub API rate limits of the CI egress.
remote_setup_script=$(mktemp /tmp/kit-infra-aws-ec2-setup.XXXXXX.sh)
cat > "${remote_setup_script}" <<'EOF'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

kit_version="$1"
kit_asset_arch="$2"
kit_sha256="$3"
kubectl_version="$4"
kit_repo="openshift-eng/kubernetes-integration-testing"

user_name="$(id -un)"
user_uid="$(id -u)"
runtime_dir="/run/user/${user_uid}"

exec > >(tee -a /tmp/kit-host-setup.log) 2>&1

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

log "Waiting for cloud-init to finish"
sudo cloud-init status --wait

log "Installing rootless Podman"
sudo apt-get update -y
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  dbus-user-session \
  fuse-overlayfs \
  jq \
  podman \
  slirp4netns \
  uidmap

log "Tuning the host for container workloads"
sudo tee /etc/sysctl.d/99-kit-host.conf >/dev/null <<'SYSCTL'
# Kubernetes workloads, especially operators, watch many files.
fs.inotify.max_user_watches = 65536
fs.inotify.max_user_instances = 8192
# The host is a dedicated ephemeral CI machine: rootless Podman must always be
# allowed to create unprivileged user namespaces, regardless of the AppArmor
# restrictions Ubuntu enables by default.
kernel.apparmor_restrict_unprivileged_userns = 0
SYSCTL
sudo sysctl --system >/dev/null

log "Ensuring subordinate UID/GID ranges for ${user_name}"
if ! grep -q "^${user_name}:" /etc/subuid || ! grep -q "^${user_name}:" /etc/subgid; then
  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${user_name}"
fi

log "Enabling lingering and the rootless Podman API socket"
sudo loginctl enable-linger "${user_name}"
export XDG_RUNTIME_DIR="${runtime_dir}"
# enable-linger starts the user manager asynchronously: retry until the
# user session accepts the socket activation request.
socket_ready=false
for attempt in $(seq 1 12); do
  if systemctl --user enable --now podman.socket; then
    socket_ready=true
    break
  fi
  log "Retrying user podman.socket activation (${attempt}/12)"
  sleep 5
done
if [[ "${socket_ready}" != true ]]; then
  log "ERROR: could not activate the rootless Podman API socket"
  exit 1
fi

log "Installing kit ${kit_version} (${kit_asset_arch})"
kit_tmp="$(mktemp /tmp/kit.XXXXXX)"
if [[ "${kit_sha256}" == "none" ]]; then
  release_json="$(curl -fsSL --retry 5 --retry-delay 5 \
    "https://api.github.com/repos/${kit_repo}/releases/tags/${kit_version}")"
  kit_url="$(printf '%s' "${release_json}" | jq -r --arg asset "kit-linux-${kit_asset_arch}" \
    '.assets[] | select(.name == $asset) | .browser_download_url')"
  kit_sha256="$(printf '%s' "${release_json}" | jq -r --arg asset "kit-linux-${kit_asset_arch}" \
    '.assets[] | select(.name == $asset) | (.digest // "") | sub("^sha256:"; "")')"
  if [[ -z "${kit_url}" || "${kit_url}" == "null" ]] || [[ -z "${kit_sha256}" ]]; then
    log "ERROR: the kit release ${kit_version} does not publish kit-linux-${kit_asset_arch} with a sha256 digest"
    exit 1
  fi
else
  kit_url="https://github.com/${kit_repo}/releases/download/${kit_version}/kit-linux-${kit_asset_arch}"
fi
curl -fsSL --retry 5 --retry-delay 5 -o "${kit_tmp}" "${kit_url}"
printf '%s  %s\n' "${kit_sha256}" "${kit_tmp}" | sha256sum --check
sudo install -m 0755 "${kit_tmp}" /usr/local/bin/kit
rm -f "${kit_tmp}"

log "Installing kubectl"
if [[ "${kubectl_version}" == "stable" ]]; then
  kubectl_version="$(curl -fsSL --retry 5 https://dl.k8s.io/release/stable.txt)"
fi
kubectl_dir="$(mktemp -d /tmp/kubectl.XXXXXX)"
curl -fsSL --retry 5 -o "${kubectl_dir}/kubectl" \
  "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${kit_asset_arch}/kubectl"
curl -fsSL --retry 5 -o "${kubectl_dir}/kubectl.sha256" \
  "https://dl.k8s.io/release/${kubectl_version}/bin/linux/${kit_asset_arch}/kubectl.sha256"
# The checksum file published by dl.k8s.io contains the bare digest without
# the filename, so the checksum record has to be built as in the upstream
# kubectl installation instructions.
(cd "${kubectl_dir}" && printf '%s  kubectl\n' "$(cat kubectl.sha256)" | sha256sum --check)
sudo install -m 0755 "${kubectl_dir}/kubectl" /usr/local/bin/kubectl
rm -rf "${kubectl_dir}"

log "Verifying the kit host"
podman --version
podman info >/dev/null
systemctl --user is-active podman.socket
podman --url "unix://${runtime_dir}/podman/podman.sock" info >/dev/null
/usr/local/bin/kit version
kubectl version --client >/dev/null
log "kit host ready: socket ${runtime_dir}/podman/podman.sock, kit /usr/local/bin/kit, kubectl /usr/local/bin/kubectl"
EOF

ssh "${SSHOPTS[@]}" "${ssh_user}@${host_address}" \
  "bash -s" -- "${KIT_VERSION}" "${asset_arch}" "${KIT_SHA256:-none}" "${KUBECTL_VERSION}" \
  < "${remote_setup_script}"

log "Kit host ${instance_id} at ${host_address} is ready"
