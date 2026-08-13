#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -x

ensure_aws_cli() {
  if command -v aws &>/dev/null; then
    return 0
  fi
  echo "Installing AWS CLI..."
  pip install awscli 2>/dev/null || pip3 install awscli
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! command -v aws &>/dev/null; then
    local user_bin
    user_bin="$(python3 -m site --user-base 2>/dev/null)/bin"
    export PATH="${user_bin}:${PATH}"
  fi
  if ! command -v aws &>/dev/null; then
    echo "ERROR: aws CLI not found after pip install (PATH=${PATH})" >&2
    exit 1
  fi
  echo "aws CLI: $(command -v aws)"
}

ensure_aws_cli

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

trap 'cleanup_on_failure' EXIT

RESOURCES_FILE="${SHARED_DIR}/evpn-bastion-resources.json"

release_bastion_eip() {
  local eip_alloc
  eip_alloc=$(jq -r '.eip_allocation_id // empty' "${RESOURCES_FILE}" 2>/dev/null || true)
  if [[ -n "${eip_alloc}" ]]; then
    echo "Releasing Elastic IP ${eip_alloc}..."
    aws --region "${REGION}" ec2 release-address --allocation-id "${eip_alloc}" 2>/dev/null || true
  fi
}

detach_worker_eni() {
  local worker_eni_id attachment_id
  worker_eni_id=$(jq -r '.worker_eni_id // empty' "${RESOURCES_FILE}" 2>/dev/null || true)
  [[ -z "${worker_eni_id}" ]] && return 0
  attachment_id=$(aws --region "${REGION}" ec2 describe-network-interfaces \
    --network-interface-ids "${worker_eni_id}" \
    --query 'NetworkInterfaces[0].Attachment.AttachmentId' --output text 2>/dev/null || true)
  if [[ -n "${attachment_id}" && "${attachment_id}" != "None" ]]; then
    echo "Detaching worker ENI ${worker_eni_id}..."
    aws --region "${REGION}" ec2 detach-network-interface \
      --attachment-id "${attachment_id}" --force 2>/dev/null || true
  fi
  echo "Deleting worker ENI ${worker_eni_id}..."
  aws --region "${REGION}" ec2 delete-network-interface \
    --network-interface-id "${worker_eni_id}" 2>/dev/null || true
}

cleanup_on_failure() {
  if [[ "$?" -ne 0 ]]; then
    echo "ERROR: Provision failed, cleaning up resources..."
    if [[ -f "${RESOURCES_FILE}" ]]; then
      local instance_id key_name
      instance_id=$(jq -r '.instance_id // empty' "${RESOURCES_FILE}" 2>/dev/null || true)
      key_name=$(jq -r '.key_name // empty' "${RESOURCES_FILE}" 2>/dev/null || true)
      detach_worker_eni
      release_bastion_eip
      [[ -n "${instance_id}" ]] && aws --region "${REGION}" ec2 terminate-instances --instance-ids "${instance_id}" 2>/dev/null || true
      [[ -n "${key_name}" ]] && aws --region "${REGION}" ec2 delete-key-pair --key-name "${key_name}" 2>/dev/null || true
    fi
  fi
}

authorize_sg_ingress() {
  local group_id=$1
  local protocol=$2
  local port=$3
  local source_group=$4
  echo "Opening ${protocol}/${port} on ${group_id} from SG ${source_group}..."
  aws --region "${REGION}" ec2 authorize-security-group-ingress \
    --group-id "${group_id}" \
    --protocol "${protocol}" \
    --port "${port}" \
    --source-group "${source_group}" 2>/dev/null || true
}

configure_evpn_security_groups() {
  local node_sg=$1
  local cp_sg=$2

  echo "=== Configuring EVPN security group rules (TCP/179 BGP, UDP/4789 VXLAN) ==="

  # Bastion uses node SG; workers/infra use node SG
  authorize_sg_ingress "${node_sg}" tcp 179 "${node_sg}"
  authorize_sg_ingress "${node_sg}" udp 4789 "${node_sg}"

  if [[ -n "${cp_sg}" && "${cp_sg}" != "None" ]]; then
    echo "Control-plane security group: ${cp_sg}"
    authorize_sg_ingress "${cp_sg}" tcp 179 "${node_sg}"
    authorize_sg_ingress "${cp_sg}" udp 4789 "${node_sg}"
    authorize_sg_ingress "${cp_sg}" tcp 179 "${cp_sg}"
    authorize_sg_ingress "${cp_sg}" udp 4789 "${cp_sg}"
    authorize_sg_ingress "${node_sg}" tcp 179 "${cp_sg}"
    authorize_sg_ingress "${node_sg}" udp 4789 "${cp_sg}"
  else
    echo "WARNING: Control-plane security group not found; only node SG rules applied" >&2
  fi

  echo "EVPN security group rules configured"
}

echo "=== Creating AWS bastion instance for network workloads ==="

INFRA_ID=$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)
echo "Cluster infra ID: ${INFRA_ID}"

# Get a worker node's AWS instance ID (PR #775 pattern)
WORKER_AWS_ID=$(oc get nodes -l node-role.kubernetes.io/worker \
  -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's|.*/||' | head -n 1)
echo "Worker instance: ${WORKER_AWS_ID}"

# Get worker's AZ, subnet, VPC, and instance type
WORKER_DETAILS=$(aws --region "${REGION}" ec2 describe-instances \
  --instance-ids "${WORKER_AWS_ID}" \
  --query 'Reservations[0].Instances[0].[Placement.AvailabilityZone,SubnetId,VpcId,InstanceType]' \
  --output json)

WORKER_AZ=$(echo "${WORKER_DETAILS}" | jq -r '.[0]')
WORKER_SUBNET=$(echo "${WORKER_DETAILS}" | jq -r '.[1]')
WORKER_VPC=$(echo "${WORKER_DETAILS}" | jq -r '.[2]')
WORKER_INSTANCE_TYPE=$(echo "${WORKER_DETAILS}" | jq -r '.[3]')

WORKER_SUBNET_CIDR=$(aws --region "${REGION}" ec2 describe-subnets \
  --subnet-ids "${WORKER_SUBNET}" \
  --query 'Subnets[0].CidrBlock' --output text)

# Machine network (VTEP CIDR) spans the whole VPC on AWS IPI, not just the worker subnet.
MACHINE_NETWORK_CIDR=$(aws --region "${REGION}" ec2 describe-vpcs \
  --vpc-ids "${WORKER_VPC}" \
  --query 'Vpcs[0].CidrBlock' --output text)
if [[ -f "${SHARED_DIR}/install-config.yaml" ]]; then
  while IFS= read -r cidr; do
    [[ "${cidr}" == *:* ]] && continue
    MACHINE_NETWORK_CIDR="${cidr}"
    break
  done < <(grep -A10 'machineNetwork:' "${SHARED_DIR}/install-config.yaml" | grep 'cidr:' | awk '{print $2}' | tr -d '"')
fi

echo "Worker AZ: ${WORKER_AZ}"
echo "Worker subnet: ${WORKER_SUBNET} (${WORKER_SUBNET_CIDR})"
echo "Worker VPC: ${WORKER_VPC}"
echo "Machine network CIDR (VTEP): ${MACHINE_NETWORK_CIDR}"
echo "Worker instance type: ${WORKER_INSTANCE_TYPE}"

# Public subnet in the worker AZ — primary ENI gets a public IP for CI SSH access.
# Worker subnets are private; their NACLs block inbound internet traffic, so an
# Elastic IP on a worker-subnet-only instance cannot be reached from CI.
PUBLIC_SUBNET=$(aws --region "${REGION}" ec2 describe-subnets \
  --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
            "Name=availability-zone,Values=${WORKER_AZ}" \
            "Name=tag:Name,Values=*public*" \
  --query 'Subnets[0].SubnetId' --output text)

echo "Public subnet (SSH): ${PUBLIC_SUBNET}"
echo "Worker subnet (EVPN): ${WORKER_SUBNET} (${WORKER_SUBNET_CIDR})"

if [[ -z "${PUBLIC_SUBNET}" || "${PUBLIC_SUBNET}" == "None" ]]; then
  echo "ERROR: No public subnet found in worker AZ ${WORKER_AZ}." >&2
  aws --region "${REGION}" ec2 describe-subnets \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
    --query 'Subnets[*].[SubnetId,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' --output table
  exit 1
fi

# Find node security group (PR #775 pattern)
SECURITY_GROUP_ID=""
for sg_id in $(aws --region "${REGION}" ec2 describe-instances \
  --instance-ids "${WORKER_AWS_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' --output text); do
  name=$(aws --region "${REGION}" ec2 describe-security-groups \
    --group-ids "${sg_id}" \
    --query 'SecurityGroups[0].GroupName' --output text)
  if [[ "${name}" == *-node ]]; then
    SECURITY_GROUP_ID="${sg_id}"
    echo "Node security group: ${SECURITY_GROUP_ID} (${name})"
    break
  fi
done

if [[ -z "${SECURITY_GROUP_ID}" ]]; then
  echo "ERROR: Could not find node security group (name ending in -node)"
  exit 1
fi

CONTROL_PLANE_SG=""
CONTROL_PLANE_SG=$(aws --region "${REGION}" ec2 describe-security-groups \
  --filters "Name=tag:sigs.k8s.io/cluster-api-provider-aws/cluster/${INFRA_ID},Values=owned" \
            "Name=tag:Name,Values=${INFRA_ID}-controlplane" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [[ -z "${CONTROL_PLANE_SG}" || "${CONTROL_PLANE_SG}" == "None" ]]; then
  CONTROL_PLANE_SG=$(aws --region "${REGION}" ec2 describe-security-groups \
    --filters "Name=tag:kubernetes.io/cluster/${INFRA_ID},Values=owned" \
              "Name=tag:Name,Values=*controlplane*" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
fi

configure_evpn_security_groups "${SECURITY_GROUP_ID}" "${CONTROL_PLANE_SG}"

# Authorize SSH from anywhere (for CI pod access)
aws --region "${REGION}" ec2 authorize-security-group-ingress \
  --group-id "${SECURITY_GROUP_ID}" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 2>/dev/null || true

# Create SSH key pair
AWS_INSTANCE_NAME="${INFRA_ID}-network-workloads"
set +e
EXISTING_KEY=$(aws --region "${REGION}" ec2 describe-key-pairs \
  --key-names "${AWS_INSTANCE_NAME}" \
  --query "KeyPairs[0].KeyName" --output text 2>/dev/null)
set -e
if [[ "${EXISTING_KEY}" == "${AWS_INSTANCE_NAME}" ]]; then
  aws --region "${REGION}" ec2 delete-key-pair --key-name "${AWS_INSTANCE_NAME}"
fi

KEY_FILE="${SHARED_DIR}/network-workloads-key.pem"
aws --region "${REGION}" ec2 create-key-pair \
  --key-name "${AWS_INSTANCE_NAME}" \
  --query 'KeyMaterial' --output text > "${KEY_FILE}"
chmod 400 "${KEY_FILE}"

# Save initial resources for cleanup-on-failure
echo '{}' | jq --arg kn "${AWS_INSTANCE_NAME}" '.key_name=$kn' > "${RESOURCES_FILE}"

# Look up Amazon Linux 2023 AMI for the region via AWS SSM
echo "Looking up Amazon Linux 2023 AMI for region ${REGION}..."
AMI_ID=$(aws --region "${REGION}" ssm get-parameter \
  --name '/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64' \
  --query 'Parameter.Value' --output text 2>/dev/null || true)
if [[ -z "${AMI_ID}" ]]; then
  AMI_ID="ami-0f7197c592205b389"
  echo "WARNING: Amazon Linux 2023 AMI not found via SSM for region ${REGION}, using default: ${AMI_ID}"
fi
echo "Amazon Linux 2023 AMI: ${AMI_ID}"

# Prepare cloud-init user-data: only set up root SSH key access.
# Package installs are done over SSH after connectivity is confirmed (more reliable
# than relying on cloud-init timing, which varies with package manager speed).
# AL2023 allows key-based root login by default (PermitRootLogin prohibit-password).
cat > /tmp/bastion-user-data.sh <<'USERDATA'
#!/bin/bash
mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp /home/ec2-user/.ssh/authorized_keys /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
chown root:root /root/.ssh/authorized_keys
USERDATA

# Launch in the public subnet (primary ENI) for CI SSH. A secondary ENI in the
# worker subnet provides the private IP used for EVPN/BGP/VXLAN with OCP nodes.
INSTANCE_TYPE="${BASTION_INSTANCE_TYPE:-${WORKER_INSTANCE_TYPE}}"
echo "Bastion instance type: ${INSTANCE_TYPE}"

set +e
INSTANCE_ID=$(aws --region "${REGION}" ec2 run-instances \
  --image-id "${AMI_ID}" \
  --count 1 \
  --instance-type "${INSTANCE_TYPE}" \
  --key-name "${AWS_INSTANCE_NAME}" \
  --subnet-id "${PUBLIC_SUBNET}" \
  --security-group-ids "${SECURITY_GROUP_ID}" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${AWS_INSTANCE_NAME}}]" \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=500,VolumeType=gp2}' \
  --user-data file:///tmp/bastion-user-data.sh \
  --query 'Instances[0].InstanceId' --output text 2>&1)
RUN_INSTANCES_RC=$?
set -e

if [[ ${RUN_INSTANCES_RC} -ne 0 || -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
  echo "ERROR: Failed to launch bastion instance (type=${INSTANCE_TYPE}, AZ=${WORKER_AZ})" >&2
  echo "${INSTANCE_ID}" >&2
  exit 1
fi

echo "Instance launched: ${INSTANCE_ID}"

# Update resources file
jq --arg id "${INSTANCE_ID}" --arg kn "${AWS_INSTANCE_NAME}" \
  --arg ws "${WORKER_SUBNET}" --arg wc "${WORKER_SUBNET_CIDR}" --arg waz "${WORKER_AZ}" \
  --arg mc "${MACHINE_NETWORK_CIDR}" \
  '.instance_id=$id | .key_name=$kn | .worker_subnet=$ws | .worker_subnet_cidr=$wc | .worker_az=$waz | .machine_network_cidr=$mc' \
  "${RESOURCES_FILE}" > "${RESOURCES_FILE}.tmp" && mv "${RESOURCES_FILE}.tmp" "${RESOURCES_FILE}"

# Wait for running
aws --region "${REGION}" ec2 wait instance-running --instance-ids "${INSTANCE_ID}"
echo "Instance is running"

# Disable source/dest check (needed for VXLAN)
aws --region "${REGION}" ec2 modify-instance-attribute \
  --instance-id "${INSTANCE_ID}" --no-source-dest-check

# Attach a secondary ENI in the worker subnet for EVPN underlay traffic.
echo "Creating worker-subnet ENI for EVPN..."
WORKER_ENI_ID=$(aws --region "${REGION}" ec2 create-network-interface \
  --subnet-id "${WORKER_SUBNET}" \
  --groups "${SECURITY_GROUP_ID}" \
  --description "${AWS_INSTANCE_NAME}-evpn" \
  --query 'NetworkInterface.NetworkInterfaceId' --output text)

# Persist ENI id before attach so cleanup can detach on failure.
jq --arg eni "${WORKER_ENI_ID}" '.worker_eni_id=$eni' \
  "${RESOURCES_FILE}" > "${RESOURCES_FILE}.tmp" && mv "${RESOURCES_FILE}.tmp" "${RESOURCES_FILE}"

aws --region "${REGION}" ec2 attach-network-interface \
  --instance-id "${INSTANCE_ID}" \
  --network-interface-id "${WORKER_ENI_ID}" \
  --device-index 1 >/dev/null

# After attach the ENI status is "in-use", not "available" — do not use
# network-interface-available here (that waiter only succeeds while detached).
echo "Waiting for worker ENI attachment..."
WORKER_ENI_ATTACHED=false
for _eni_wait in $(seq 1 30); do
  attach_status=$(aws --region "${REGION}" ec2 describe-network-interfaces \
    --network-interface-ids "${WORKER_ENI_ID}" \
    --query 'NetworkInterfaces[0].Attachment.Status' --output text 2>/dev/null || true)
  if [[ "${attach_status}" == "attached" ]]; then
    echo "Worker ENI attached (attempt ${_eni_wait})"
    WORKER_ENI_ATTACHED=true
    break
  fi
  sleep 2
done
if [[ "${WORKER_ENI_ATTACHED}" != "true" ]]; then
  echo "ERROR: Worker ENI ${WORKER_ENI_ID} did not reach attached state after 60s" >&2
  exit 1
fi

PRIVATE_IP=$(aws --region "${REGION}" ec2 describe-network-interfaces \
  --network-interface-ids "${WORKER_ENI_ID}" \
  --query 'NetworkInterfaces[0].PrivateIpAddress' --output text)

INSTANCE_INFO=$(aws --region "${REGION}" ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].[PublicDnsName,PublicIpAddress]' \
  --output json)
PUBLIC_DNS=$(echo "${INSTANCE_INFO}" | jq -r '.[0]')
PUBLIC_IP=$(echo "${INSTANCE_INFO}" | jq -r '.[1]')
# Prefer public DNS for SSH (matches prior working runs); fall back to public IP.
SSH_HOST="${PUBLIC_DNS}"
[[ -z "${SSH_HOST}" || "${SSH_HOST}" == "None" ]] && SSH_HOST="${PUBLIC_IP}"

echo "Public address (SSH): ${SSH_HOST}"
echo "Worker ENI private IP (EVPN): ${PRIVATE_IP} (${WORKER_ENI_ID})"

jq --arg pip "${PRIVATE_IP}" --arg eni "${WORKER_ENI_ID}" \
  '.bastion_private_ip=$pip | .worker_eni_id=$eni' \
  "${RESOURCES_FILE}" > "${RESOURCES_FILE}.tmp" && mv "${RESOURCES_FILE}.tmp" "${RESOURCES_FILE}"

# bastion_public_address is the SSH target; bastion_private_address is for EVPN traffic.
echo "${SSH_HOST}" > "${SHARED_DIR}/bastion_public_address"
echo "${PRIVATE_IP}" > "${SHARED_DIR}/bastion_private_address"
echo "root" > "${SHARED_DIR}/bastion_ssh_user"
echo "${INSTANCE_ID}" >> "${SHARED_DIR}/aws-instance-ids.txt"

# Copy SSH key for the EVPN step
cp "${KEY_FILE}" "${SHARED_DIR}/bastion_ssh_key"

echo "Waiting 60s for instance to boot and cloud-init (root SSH key setup) to complete..."
sleep 60

# Verify SSH connectivity
SSH_ARGS="-i ${KEY_FILE} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"
SSH_OK=false
for attempt in $(seq 1 5); do
  if ssh ${SSH_ARGS} "root@${SSH_HOST}" "echo 'SSH OK'"; then
    echo "SSH connectivity verified"
    SSH_OK=true
    break
  fi
  echo "SSH attempt ${attempt}/5 failed, retrying in 30s..."
  sleep 30
done

if [[ "${SSH_OK}" != "true" ]]; then
  echo "ERROR: SSH connectivity to bastion ${SSH_HOST} failed after 5 attempts" >&2
  exit 1
fi

# Install all packages and tools needed by the EVPN step.
# Done here over SSH (post-boot) rather than cloud-init to avoid timing races.
echo "=== Installing bastion tools ==="
ssh ${SSH_ARGS} "root@${SSH_HOST}" bash -s <<'BASTION_INSTALL'
set -o errexit
set -o pipefail

echo "--- Installing system packages ---"
# iproute provides ip and bridge (bridge vlan) used by setup/cleanup scripts
# jq, wget, git are often preinstalled on AL2023 — install only if missing
for pkg in iproute jq wget git; do
  rpm -q "${pkg}" &>/dev/null || dnf install -y "${pkg}"
done

# podman is not in the default AL2023 repos; enable SPAL first.
# https://docs.aws.amazon.com/linux/al2023/ug/spal.html
if ! command -v podman &>/dev/null; then
  echo "Enabling SPAL repository for podman..."
  dnf install -y spal-release
  dnf install -y podman
fi

echo "--- Installing OpenShift CLI (oc) ---"
curl -sSL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
  | tar -xzf - -C /usr/local/bin/ oc kubectl
echo "oc: $(oc version --client 2>/dev/null | head -1)"

echo "--- Installing Go ---"
GO_VERSION=1.23.4
curl -sSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xzf -
# Symlink into /usr/local/bin so 'go' is on the default SSH PATH
ln -sf /usr/local/go/bin/go /usr/local/bin/go
echo "go: $(go version)"

echo "--- Tool versions ---"
command -v podman >/dev/null && podman --version
ip -V 2>/dev/null || true
command -v bridge >/dev/null && bridge -V 2>/dev/null || true
jq --version
git --version
BASTION_INSTALL

# Copy kubeconfig to the default path so 'oc' on the bastion works without
# passing KUBECONFIG on every SSH call in later steps (e.g. openshift-qe-evpn).
echo "=== Copying kubeconfig to bastion ==="
ssh ${SSH_ARGS} "root@${SSH_HOST}" "mkdir -p /root/.kube"
scp ${SSH_ARGS} "${KUBECONFIG}" "root@${SSH_HOST}:/root/.kube/config"
ssh ${SSH_ARGS} "root@${SSH_HOST}" "chmod 600 /root/.kube/config"

echo "=== Bastion instance created ==="
echo "  Instance ID: ${INSTANCE_ID}"
echo "  Public address (SSH): ${SSH_HOST}"
echo "  Worker ENI private IP (EVPN): ${PRIVATE_IP}"
echo "  Worker AZ: ${WORKER_AZ}"
echo "  Worker subnet CIDR: ${WORKER_SUBNET_CIDR}"
echo "  Machine network CIDR (VTEP): ${MACHINE_NETWORK_CIDR}"
