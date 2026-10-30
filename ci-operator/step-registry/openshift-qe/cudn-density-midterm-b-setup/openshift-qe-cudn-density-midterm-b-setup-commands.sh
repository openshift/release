#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

export AWS_DEFAULT_REGION="${AWS_REGION}"
AWS_CREDS="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_ACCESS_KEY_ID=$(grep aws_access_key_id "${AWS_CREDS}" | awk '{print $3}')
export AWS_SECRET_ACCESS_KEY=$(grep aws_secret_access_key "${AWS_CREDS}" | awk '{print $3}')

# Pick first two worker nodes in single AZ
CLIENT_NODE=$(oc get nodes -l node-role.kubernetes.io/worker \
  --no-headers \
  -o custom-columns=NAME:.metadata.name,AZ:.metadata.labels."topology\.kubernetes\.io/zone" \
  | sort -k2 | head -1 | awk '{print $1}')
SERVER_NODE=$(oc get nodes -l node-role.kubernetes.io/worker \
  --no-headers \
  -o custom-columns=NAME:.metadata.name,AZ:.metadata.labels."topology\.kubernetes\.io/zone" \
  | sort -k2 | sed -n '2p' | awk '{print $1}')

echo "CLIENT_NODE=$CLIENT_NODE SERVER_NODE=$SERVER_NODE"
echo "${CLIENT_NODE}" > "${SHARED_DIR}/ext_client_node"
echo "${SERVER_NODE}" > "${SHARED_DIR}/ext_server_node"

# Get VPC/subnet/SG/AZ/AMI from existing worker
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

AMI_ID=$(aws ec2 describe-instances --instance-ids "${WORKER_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].ImageId' --output text)

SUBNET_CIDR=$(aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" \
  --query 'Subnets[0].CidrBlock' --output text)

echo "VPC=$VPC_ID SUBNET=$SUBNET_ID SG=$SG_ID AZ=$AZ AMI=$AMI_ID CIDR=$SUBNET_CIDR"

# Dynamically find 25 consecutive unused IPs in subnet
NODE_IPS=$(oc get nodes \
  -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n')
AWS_IPS=$(aws ec2 describe-network-interfaces \
  --filters "Name=subnet-id,Values=${SUBNET_ID}" \
  --query 'NetworkInterfaces[*].PrivateIpAddresses[*].PrivateIpAddress' \
  --output text | tr '\t' '\n')
ALL_USED=$(echo -e "${NODE_IPS}\n${AWS_IPS}" | sort -u)

IP_RANGE=$(python3 -c "
import ipaddress
used = set('''${ALL_USED}'''.split())
net = ipaddress.ip_network('${SUBNET_CIDR}')
free = []
for ip in net.hosts():
    s = str(ip)
    if s not in used:
        free.append(s)
    if len(free) == ${MAX_TARGETS}:
        print(free[0], free[-1])
        break
")

START_IP=$(echo "${IP_RANGE}" | awk '{print $1}')
END_IP=$(echo "${IP_RANGE}" | awk '{print $2}')
echo "Using external IP range: ${START_IP} - ${END_IP}"
echo "${START_IP}" > "${SHARED_DIR}/ext_start_ip"
echo "${END_IP}" > "${SHARED_DIR}/ext_end_ip"

# Create fresh key pair
KEY_NAME="midterm-b-$(date +%s)"
aws ec2 create-key-pair --key-name "${KEY_NAME}" \
  --query 'KeyMaterial' --output text > /tmp/ssh.pem
chmod 600 /tmp/ssh.pem
echo "${KEY_NAME}" > "${SHARED_DIR}/ext_key_name"

# Launch external instance with new key pair
EXT_INSTANCE_ID=$(aws ec2 run-instances \
  --instance-type "${EXTERNAL_INSTANCE_TYPE}" \
  --image-id "${AMI_ID}" \
  --key-name "${KEY_NAME}" \
  --subnet-id "${SUBNET_ID}" \
  --security-group-ids "${SG_ID}" \
  --no-associate-public-ip-address \
  --placement "AvailabilityZone=${AZ}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=midterm-b-external}]" \
  --query 'Instances[0].InstanceId' --output text)

echo "EXT_INSTANCE_ID=${EXT_INSTANCE_ID}"
echo "${EXT_INSTANCE_ID}" > "${SHARED_DIR}/ext_instance_id"

aws ec2 wait instance-running --instance-ids "${EXT_INSTANCE_ID}"
sleep 30

EXT_IP=$(aws ec2 describe-instances --instance-ids "${EXT_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "EXT_IP=${EXT_IP}"
echo "${EXT_IP}" > "${SHARED_DIR}/ext_ip"

ENI_ID=$(aws ec2 describe-instances --instance-ids "${EXT_INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)

# Assign secondary IPs
SECONDARY_IPS=$(python3 -c "
import ipaddress
start = ipaddress.ip_address('${START_IP}')
end = ipaddress.ip_address('${END_IP}')
ips = []
current = start
while current <= end:
    ips.append(str(current))
    current += 1
print(' '.join(ips))
")

aws ec2 assign-private-ip-addresses \
  --network-interface-id "${ENI_ID}" \
  --private-ip-addresses ${SECONDARY_IPS}

echo "Assigned ${MAX_TARGETS} secondary IPs to ${ENI_ID}"

# Download and fix ipvlan script
curl -sL -o /tmp/create-ipvlan-targets.sh \
  'https://gist.githubusercontent.com/venkataanil/20955f74c0364bf8a530f3c6e1cad6a2/raw/gistfile1.txt'

# Extract third and fourth octets from IP range
THIRD_OCTET=$(echo "${START_IP}" | cut -d. -f3)
START_FOURTH=$(echo "${START_IP}" | cut -d. -f4)
END_FOURTH=$(echo "${END_IP}" | cut -d. -f4)

sed -i "s/for third in [0-9]*/for third in ${THIRD_OCTET}/" /tmp/create-ipvlan-targets.sh
sed -i "s/for fourth in \$(seq [0-9]* [0-9]*)/for fourth in \$(seq ${START_FOURTH} ${END_FOURTH})/" \
  /tmp/create-ipvlan-targets.sh

# Copy PEM and ipvlan script to worker node
oc debug node/"${CLIENT_NODE}" -- bash -c "cat > /host/tmp/midterm-ssh.pem" < /tmp/ssh.pem
oc debug node/"${CLIENT_NODE}" -- bash -c "chmod 600 /host/tmp/midterm-ssh.pem"
oc debug node/"${CLIENT_NODE}" -- bash -c "cat > /host/tmp/create-ipvlan-targets.sh" \
  < /tmp/create-ipvlan-targets.sh

# SSH from worker to external instance: wait for IPs, remove them, run ipvlan setup
EXPECTED_COUNT=$(( ${MAX_TARGETS} + 1 ))  # primary + secondary

oc debug node/"${CLIENT_NODE}" -- bash -c "
chroot /host

# Wait for SSH to be ready on external instance
for i in \$(seq 1 30); do
  ssh -i /tmp/midterm-ssh.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    ec2-user@${EXT_IP} 'echo ready' 2>/dev/null && break
  echo 'Waiting for SSH... attempt '\$i
  sleep 10
done

# Copy ipvlan script to external instance
scp -i /tmp/midterm-ssh.pem -o StrictHostKeyChecking=no \
  /tmp/create-ipvlan-targets.sh ec2-user@${EXT_IP}:/tmp/

# On external instance: wait for IPs, remove them, run ipvlan
ssh -i /tmp/midterm-ssh.pem -o StrictHostKeyChecking=no ec2-user@${EXT_IP} 'sudo bash -s' << 'REMOTE'
# Find default interface
IFACE=\$(ip route | grep default | awk '{print \$5}' | head -1)
echo \"Interface: \$IFACE\"

# Wait for all secondary IPs to appear (up to 10 minutes)
EXPECTED=${EXPECTED_COUNT}
for attempt in \$(seq 1 60); do
  CURRENT=\$(ip a show \$IFACE | grep \"inet \" | wc -l)
  echo \"Attempt \$attempt: \$CURRENT/\$EXPECTED IPs on \$IFACE\"
  [ \"\$CURRENT\" -ge \"\$EXPECTED\" ] && break
  sleep 10
done

# Remove secondary IPs (AWS auto-added them)
for ip in \$(ip a show \$IFACE | grep \"inet \" | grep secondary | awk '{print \$2}'); do
  ip a d \$ip dev \$IFACE 2>/dev/null || true
done
echo 'Secondary IPs removed'
ip a show \$IFACE | grep 'inet '

# Run ipvlan setup
chmod +x /tmp/create-ipvlan-targets.sh
UPLINK=\$IFACE MAX_TARGETS=${MAX_TARGETS} bash /tmp/create-ipvlan-targets.sh
REMOTE
"

echo "Setup complete. External instance ${EXT_IP} ready with ${MAX_TARGETS} ipvlan targets (${START_IP}-${END_IP})"
