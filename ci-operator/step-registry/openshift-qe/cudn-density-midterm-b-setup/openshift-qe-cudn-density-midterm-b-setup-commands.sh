#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Read AWS credentials without xtrace to avoid log exposure (SC2155: declare separately)
set +x
AWS_CREDS="${CLUSTER_PROFILE_DIR}/.awscred"
AWS_ACCESS_KEY_ID=$(grep aws_access_key_id "${AWS_CREDS}" | awk '{print $3}')
export AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=$(grep aws_secret_access_key "${AWS_CREDS}" | awk '{print $3}')
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="${AWS_REGION}"
set -x

# Pick first two worker nodes in single AZ
CLIENT_NODE=$(oc get nodes -l node-role.kubernetes.io/worker \
  --no-headers \
  -o custom-columns=NAME:.metadata.name,AZ:.metadata.labels."topology\.kubernetes\.io/zone" \
  | sort -k2 | head -1 | awk '{print $1}')
SERVER_NODE=$(oc get nodes -l node-role.kubernetes.io/worker \
  --no-headers \
  -o custom-columns=NAME:.metadata.name,AZ:.metadata.labels."topology\.kubernetes\.io/zone" \
  | sort -k2 | sed -n '2p' | awk '{print $1}')

echo "CLIENT_NODE=${CLIENT_NODE} SERVER_NODE=${SERVER_NODE}"
echo "${CLIENT_NODE}" > "${SHARED_DIR}/ext_client_node"
echo "${SERVER_NODE}" > "${SHARED_DIR}/ext_server_node"

# Get VPC/subnet/SG/AZ/cluster-tag from existing worker
WORKER_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=private-dns-name,Values=${CLIENT_NODE}" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

VPC_ID=$(aws ec2 describe-instances --instance-ids "${WORKER_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].VpcId' --output text)

SUBNET_ID=$(aws ec2 describe-instances --instance-ids "${WORKER_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SubnetId' --output text)

SG_ID=$(aws ec2 describe-instances --instance-ids "${WORKER_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups[?contains(GroupName,`node`)].GroupId | [0]' \
  --output text)

AZ=$(aws ec2 describe-instances --instance-ids "${WORKER_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)

CLUSTER_TAG=$(aws ec2 describe-instances --instance-ids "${WORKER_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].Tags[?starts_with(Key,`kubernetes.io/cluster/`)].Key | [0]' \
  --output text)

echo "VPC=${VPC_ID} SUBNET=${SUBNET_ID} SG=${SG_ID} AZ=${AZ} CLUSTER_TAG=${CLUSTER_TAG}"

# Use Amazon Linux 2023 AMI — supports ec2-user and secondary IP auto-assignment
# RHCOS worker AMI uses 'core' user and is not suitable for external target instance
AL2023_AMI=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
echo "Using Amazon Linux 2023 AMI: ${AL2023_AMI}"

# Dynamically find MAX_TARGETS consecutive unused IPs, excluding AWS reserved (.0-.3, last)
SUBNET_CIDR=$(aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" \
  --query 'Subnets[0].CidrBlock' --output text)

AWS_IPS=$(aws ec2 describe-network-interfaces \
  --filters "Name=subnet-id,Values=${SUBNET_ID}" \
  --query 'NetworkInterfaces[*].PrivateIpAddresses[*].PrivateIpAddress' \
  --output text | tr '\t\n' ' ')

IP_RANGE=$(python3 -c "
import ipaddress, sys
used = set('${AWS_IPS}'.split())
net = ipaddress.ip_network('${SUBNET_CIDR}')
# AWS reserves .0-.3 and last address
hosts = list(net.hosts())
reserved = {str(net.network_address), str(net.broadcast_address),
            str(hosts[0]), str(hosts[1]), str(hosts[2])}
used |= reserved
count = int('${MAX_TARGETS}')
consecutive = []
for ip in hosts:
    s = str(ip)
    if s in used:
        consecutive = []
        continue
    consecutive.append(s)
    if len(consecutive) == count:
        print(consecutive[0], consecutive[-1])
        sys.exit(0)
print('ERROR: not enough consecutive free IPs in subnet', file=sys.stderr)
sys.exit(1)
")

START_IP=$(echo "${IP_RANGE}" | awk '{print $1}')
END_IP=$(echo "${IP_RANGE}" | awk '{print $2}')
echo "External target IP range: ${START_IP} - ${END_IP}"
echo "${START_IP}" > "${SHARED_DIR}/ext_start_ip"
echo "${END_IP}" > "${SHARED_DIR}/ext_end_ip"

# Create fresh key pair without xtrace (SC2155: declare separately)
set +x
KEY_NAME="midterm-b-$(date +%s)"
aws ec2 create-key-pair --key-name "${KEY_NAME}" \
  --query 'KeyMaterial' --output text > /tmp/ssh.pem
chmod 600 /tmp/ssh.pem
set -x
echo "${KEY_NAME}" > "${SHARED_DIR}/ext_key_name"

# Launch external instance — tag with cluster ownership so cluster destroy can clean it up
EXT_INSTANCE_ID=$(aws ec2 run-instances \
  --instance-type "${EXTERNAL_INSTANCE_TYPE}" \
  --image-id "${AL2023_AMI}" \
  --key-name "${KEY_NAME}" \
  --subnet-id "${SUBNET_ID}" \
  --security-group-ids "${SG_ID}" \
  --no-associate-public-ip-address \
  --placement "AvailabilityZone=${AZ}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=midterm-b-external},{Key=${CLUSTER_TAG},Value=owned}]" \
  --query 'Instances[0].InstanceId' --output text)

echo "${EXT_INSTANCE_ID}" > "${SHARED_DIR}/ext_instance_id"
echo "Waiting for instance ${EXT_INSTANCE_ID} to be running..."
aws ec2 wait instance-running --instance-ids "${EXT_INSTANCE_ID}"
sleep 30

EXT_IP=$(aws ec2 describe-instances --instance-ids "${EXT_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "${EXT_IP}" > "${SHARED_DIR}/ext_ip"

ENI_ID=$(aws ec2 describe-instances --instance-ids "${EXT_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)

# Assign consecutive secondary IPs
SECONDARY_IPS=$(python3 -c "
import ipaddress
start = ipaddress.ip_address('${START_IP}')
end = ipaddress.ip_address('${END_IP}')
ips = []
while start <= end:
    ips.append(str(start))
    start += 1
print(' '.join(ips))
")
aws ec2 assign-private-ip-addresses \
  --network-interface-id "${ENI_ID}" \
  --private-ip-addresses ${SECONDARY_IPS}
echo "Assigned ${MAX_TARGETS} secondary IPs (${START_IP}-${END_IP}) to ${ENI_ID}"

# Download and patch ipvlan script (third/fourth octet)
curl -sL -o /tmp/create-ipvlan-targets.sh \
  'https://gist.githubusercontent.com/venkataanil/20955f74c0364bf8a530f3c6e1cad6a2/raw/gistfile1.txt'

THIRD_OCTET=$(echo "${START_IP}" | cut -d. -f3)
START_FOURTH=$(echo "${START_IP}" | cut -d. -f4)
END_FOURTH=$(echo "${END_IP}" | cut -d. -f4)
sed -i "s/for third in [0-9]*/for third in ${THIRD_OCTET}/" /tmp/create-ipvlan-targets.sh
sed -i "s/for fourth in \$(seq [0-9]* [0-9]*)/for fourth in \$(seq ${START_FOURTH} ${END_FOURTH})/" \
  /tmp/create-ipvlan-targets.sh

# Copy PEM and ipvlan script to worker node host filesystem
oc debug node/"${CLIENT_NODE}" -- bash -c "cat > /host/tmp/midterm-ssh.pem" < /tmp/ssh.pem
oc debug node/"${CLIENT_NODE}" -- bash -c "chmod 600 /host/tmp/midterm-ssh.pem"
oc debug node/"${CLIENT_NODE}" -- bash -c "cat > /host/tmp/create-ipvlan-targets.sh" < /tmp/create-ipvlan-targets.sh

EXPECTED_COUNT=$(( MAX_TARGETS + 1 ))

# SSH from worker to external instance — use chroot /host as command (not shell builtin)
oc debug node/"${CLIENT_NODE}" -- chroot /host bash -c "
set -e

SSH_READY=false
for i in \$(seq 1 30); do
  ssh -i /tmp/midterm-ssh.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    ec2-user@${EXT_IP} 'echo ready' 2>/dev/null && SSH_READY=true && break
  echo 'Waiting for SSH... attempt '\$i
  sleep 10
done
if [ \"\$SSH_READY\" != \"true\" ]; then
  echo 'ERROR: SSH to ${EXT_IP} failed after 30 attempts' >&2
  exit 1
fi

scp -i /tmp/midterm-ssh.pem -o StrictHostKeyChecking=no \
  /tmp/create-ipvlan-targets.sh ec2-user@${EXT_IP}:/tmp/

ssh -i /tmp/midterm-ssh.pem -o StrictHostKeyChecking=no ec2-user@${EXT_IP} sudo bash << 'REMOTE'
set -e
IFACE=\$(ip route | grep default | awk '{print \$5}' | head -1)
echo \"Interface: \$IFACE\"

for attempt in \$(seq 1 60); do
  CURRENT=\$(ip a show \$IFACE | grep 'inet ' | wc -l)
  echo \"Attempt \$attempt: \$CURRENT/${EXPECTED_COUNT} IPs on \$IFACE\"
  [ \"\$CURRENT\" -ge \"${EXPECTED_COUNT}\" ] && break
  sleep 10
done

ip a show \$IFACE | grep 'inet ' | grep secondary | awk '{print \$2}' | while read ip; do
  ip a d \$ip dev \$IFACE 2>/dev/null || true
done
echo 'Secondary IPs removed'

chmod +x /tmp/create-ipvlan-targets.sh
UPLINK=\$IFACE MAX_TARGETS=${MAX_TARGETS} bash /tmp/create-ipvlan-targets.sh
REMOTE
"

echo "Setup complete: ${EXT_IP}, IPs ${START_IP}-${END_IP}"
