#!/bin/bash
set -euo pipefail

echo "--- Provisioning ipecho bastion instance ---"

# Configure AWS credentials
export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-pool-aws-credentials/.awscred"
export AWS_DEFAULT_REGION="${HYPERSHIFT_AWS_REGION}"

EXPIRATION_DATE=$(date -u -d "+24 hours" '+%Y-%m-%dT%H:%M:%SZ')
echo "Resources will be tagged with expirationDate=${EXPIRATION_DATE}"

# --- 1. Look up default VPC ---
echo "Looking up default VPC in region ${AWS_DEFAULT_REGION}..."
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)

if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  echo "ERROR: No default VPC found in region ${AWS_DEFAULT_REGION}"
  exit 1
fi
echo "Default VPC: ${VPC_ID}"

# --- 2. Find a default public subnet ---
echo "Looking up a public subnet in VPC ${VPC_ID}..."
SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
            "Name=default-for-az,Values=true" \
            "Name=map-public-ip-on-launch,Values=true" \
  --query "Subnets[0].SubnetId" --output text)

if [[ -z "${SUBNET_ID}" || "${SUBNET_ID}" == "None" ]]; then
  echo "ERROR: No default public subnet found in VPC ${VPC_ID}"
  exit 1
fi
echo "Public subnet: ${SUBNET_ID}"

# --- 3. Create security group ---
echo "Creating security group for ipecho bastion..."
SG_ID=$(aws ec2 create-security-group \
  --group-name "ipecho-bastion-${NAMESPACE}-${UNIQUE_HASH}" \
  --description "ipecho bastion for CI job ${JOB_NAME}" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=ipecho-bastion-${NAMESPACE}},{Key=expirationDate,Value=${EXPIRATION_DATE}}]" \
  --query "GroupId" --output text)
echo "Security group: ${SG_ID}"

aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
  --protocol tcp --port "${IPECHO_PORT}" --cidr "0.0.0.0/0" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" \
  --protocol tcp --port 22 --cidr "0.0.0.0/0" >/dev/null
echo "Ingress rules added for TCP ${IPECHO_PORT} and TCP 22"

# --- 4. Look up latest Amazon Linux 2023 AMI ---
echo "Looking up latest Amazon Linux 2023 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
            "Name=state,Values=available" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" --output text)

if [[ -z "${AMI_ID}" || "${AMI_ID}" == "None" ]]; then
  echo "ERROR: Could not find Amazon Linux 2023 AMI"
  exit 1
fi
echo "AMI: ${AMI_ID}"

# --- 5. Generate user-data with ipecho systemd service ---
USER_DATA=$(cat <<'USERDATA'
#!/bin/bash
cat > /usr/local/bin/ipecho.py << 'PYEOF'
#!/usr/bin/env python3
import http.server
import socketserver
import sys

class IPEchoHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        client_ip = self.client_address[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(client_ip.encode("utf-8"))
        self.wfile.write(b"\n")

    def log_message(self, format, *args):
        pass

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9095
    with socketserver.TCPServer(("", port), IPEchoHandler) as httpd:
        print(f"ipecho listening on port {port}")
        httpd.serve_forever()
PYEOF
chmod +x /usr/local/bin/ipecho.py

cat > /etc/systemd/system/ipecho.service << SVCEOF
[Unit]
Description=IP Echo HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ipecho.py IPECHO_PORT_PLACEHOLDER
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVCEOF

sed -i "s/IPECHO_PORT_PLACEHOLDER/${IPECHO_PORT:-9095}/" /etc/systemd/system/ipecho.service
systemctl daemon-reload
systemctl enable --now ipecho.service
USERDATA
)

# Replace the placeholder with the actual port in user-data
USER_DATA="${USER_DATA//IPECHO_PORT_PLACEHOLDER/${IPECHO_PORT}}"

USER_DATA_B64=$(echo "${USER_DATA}" | base64 -w0)

# --- 6. Launch instance ---
echo "Launching t3.micro instance..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "${AMI_ID}" \
  --instance-type t3.micro \
  --subnet-id "${SUBNET_ID}" \
  --security-group-ids "${SG_ID}" \
  --associate-public-ip-address \
  --user-data "${USER_DATA_B64}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ipecho-bastion-${NAMESPACE}},{Key=expirationDate,Value=${EXPIRATION_DATE}}]" \
  --query "Instances[0].InstanceId" --output text)
echo "Instance: ${INSTANCE_ID}"

# --- 7. Wait for instance to be running ---
echo "Waiting for instance to reach running state..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}"

PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)

if [[ -z "${PUBLIC_IP}" || "${PUBLIC_IP}" == "None" ]]; then
  echo "ERROR: Instance ${INSTANCE_ID} has no public IP"
  exit 1
fi
echo "Public IP: ${PUBLIC_IP}"

IPECHO_URL="http://${PUBLIC_IP}:${IPECHO_PORT}"
echo "ipecho URL: ${IPECHO_URL}"

# Poll the ipecho endpoint up to 30 retries (10s apart = ~5 min)
echo "Waiting for ipecho service to respond..."
RETRIES=30
for i in $(seq 1 ${RETRIES}); do
  if curl -s --connect-timeout 5 --max-time 10 "${IPECHO_URL}" >/dev/null 2>&1; then
    echo "ipecho is responding (attempt ${i}/${RETRIES})"
    break
  fi
  if [[ ${i} -eq ${RETRIES} ]]; then
    echo "ERROR: ipecho did not respond after ${RETRIES} attempts"
    # Write files so deprovision can still clean up
    echo "${INSTANCE_ID}" > "${SHARED_DIR}/ipecho_instance_id"
    echo "${SG_ID}" > "${SHARED_DIR}/ipecho_security_group_id"
    echo "${AWS_DEFAULT_REGION}" > "${SHARED_DIR}/ipecho_region"
    exit 1
  fi
  echo "  Attempt ${i}/${RETRIES}: not yet responding, retrying in 10s..."
  sleep 10
done

# --- 8. Write outputs to SHARED_DIR ---
echo "${INSTANCE_ID}" > "${SHARED_DIR}/ipecho_instance_id"
echo "${SG_ID}" > "${SHARED_DIR}/ipecho_security_group_id"
echo "${AWS_DEFAULT_REGION}" > "${SHARED_DIR}/ipecho_region"
echo "${PUBLIC_IP}" > "${SHARED_DIR}/ipecho_public_ip"
echo "${IPECHO_URL}" > "${SHARED_DIR}/ipecho_url"

echo "--- ipecho bastion provisioned successfully ---"
echo "  Instance ID:     ${INSTANCE_ID}"
echo "  Security Group:  ${SG_ID}"
echo "  Region:          ${AWS_DEFAULT_REGION}"
echo "  Public IP:       ${PUBLIC_IP}"
echo "  URL:             ${IPECHO_URL}"
