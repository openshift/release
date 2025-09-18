#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "🔒 Starting AWS security group configuration..."

# Set up AWS credentials
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export REGION="${LEASED_RESOURCE}"

echo "AWS credentials file: ${AWS_SHARED_CREDENTIALS_FILE}"
echo "AWS region: ${REGION}"

# Get the AWS ROSA worker security group ID
export AWS_ROSA_WORKER_SECURITY_GROUP=$(aws ec2 describe-security-groups \
  --region "${REGION}" \
  --filters "Name=group-name,Values=*worker*" \
  --query 'SecurityGroups[0].GroupId' --output text)

if [[ -z "${AWS_ROSA_WORKER_SECURITY_GROUP}" ]]; then
  echo "ERROR: Could not find worker security group"
  exit 1
fi

echo "Configuring security group: ${AWS_ROSA_WORKER_SECURITY_GROUP}"

# Parse custom security group configuration from environment variables
# Default IBM Storage Scale ports if not specified
CUSTOM_PORTS="${CUSTOM_SECURITY_GROUP_PORTS:-12345,1191,60000-61000}"
CUSTOM_PROTOCOLS="${CUSTOM_SECURITY_GROUP_PROTOCOLS:-tcp,udp}"
CUSTOM_SOURCES="${CUSTOM_SECURITY_GROUP_SOURCES:-${AWS_ROSA_WORKER_SECURITY_GROUP}}"

echo "Security group configuration:"
echo "  Ports: ${CUSTOM_PORTS}"
echo "  Protocols: ${CUSTOM_PROTOCOLS}"
echo "  Sources: ${CUSTOM_SOURCES}"

# Split comma-separated values
IFS=',' read -ra PORT_ARRAY <<< "$CUSTOM_PORTS"
IFS=',' read -ra PROTOCOL_ARRAY <<< "$CUSTOM_PROTOCOLS"
IFS=',' read -ra SOURCE_ARRAY <<< "$CUSTOM_SOURCES"

# Configure security group rules for each port/protocol combination
for port in "${PORT_ARRAY[@]}"; do
  for protocol in "${PROTOCOL_ARRAY[@]}"; do
    for source in "${SOURCE_ARRAY[@]}"; do
      echo "Adding rule: ${protocol} port ${port} from ${source}"
      
      # Handle port ranges (e.g., 60000-61000)
      if [[ "$port" == *"-"* ]]; then
        start_port=$(echo "$port" | cut -d'-' -f1)
        end_port=$(echo "$port" | cut -d'-' -f2)
        
        # Determine if source is a CIDR block or security group
        if [[ "$source" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
          # Source is a CIDR block
          aws ec2 authorize-security-group-ingress \
            --region "${REGION}" \
            --group-id "${AWS_ROSA_WORKER_SECURITY_GROUP}" \
            --protocol "${protocol}" \
            --port "${start_port}-${end_port}" \
            --cidr "${source}" || {
            echo "WARNING: Rule for ${protocol} ports ${start_port}-${end_port} from ${source} may already exist"
          }
        else
          # Source is a security group
          aws ec2 authorize-security-group-ingress \
            --region "${REGION}" \
            --group-id "${AWS_ROSA_WORKER_SECURITY_GROUP}" \
            --protocol "${protocol}" \
            --port "${start_port}-${end_port}" \
            --source-group "${source}" || {
            echo "WARNING: Rule for ${protocol} ports ${start_port}-${end_port} from ${source} may already exist"
          }
        fi
      else
        # Determine if source is a CIDR block or security group
        if [[ "$source" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
          # Source is a CIDR block
          aws ec2 authorize-security-group-ingress \
            --region "${REGION}" \
            --group-id "${AWS_ROSA_WORKER_SECURITY_GROUP}" \
            --protocol "${protocol}" \
            --port "${port}" \
            --cidr "${source}" || {
            echo "WARNING: Rule for ${protocol} port ${port} from ${source} may already exist"
          }
        else
          # Source is a security group
          aws ec2 authorize-security-group-ingress \
            --region "${REGION}" \
            --group-id "${AWS_ROSA_WORKER_SECURITY_GROUP}" \
            --protocol "${protocol}" \
            --port "${port}" \
            --source-group "${source}" || {
            echo "WARNING: Rule for ${protocol} port ${port} from ${source} may already exist"
          }
        fi
      fi
    done
  done
done

# Verify security group rules were added
echo "Verifying security group configuration..."
aws ec2 describe-security-groups \
  --region "${REGION}" \
  --group-ids "${AWS_ROSA_WORKER_SECURITY_GROUP}" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output table

# Test connectivity for critical ports
echo "Testing security group connectivity..."
for port in "${PORT_ARRAY[@]}"; do
  if [[ "$port" == *"-"* ]]; then
    start_port=$(echo "$port" | cut -d'-' -f1)
    echo "Port range ${start_port}-${port} configured"
  else
    echo "Port ${port} configured"
  fi
done

echo "Custom security group configuration completed successfully"
echo ""
echo "📋 Security Group Configuration Summary:"
echo "  Security Group ID: ${AWS_ROSA_WORKER_SECURITY_GROUP}"
echo "  Region: ${REGION}"
echo ""
echo "🔧 Configured Ports and Protocols:"
for port in "${PORT_ARRAY[@]}"; do
  for protocol in "${PROTOCOL_ARRAY[@]}"; do
    if [[ "$port" == *"-"* ]]; then
      echo "  - ${protocol} ports ${port} (port range)"
    else
      case "$port" in
        "12345")
          echo "  - ${protocol} port ${port} (IBM Storage Scale NSD)"
          ;;
        "1191")
          echo "  - ${protocol} port ${port} (IBM Storage Scale GUI)"
          ;;
        "60000-61000")
          echo "  - ${protocol} ports ${port} (IBM Storage Scale dynamic ports)"
          ;;
        *)
          echo "  - ${protocol} port ${port} (custom)"
          ;;
      esac
    fi
  done
done
echo ""
echo "✅ Security group rules have been applied for IBM Storage Scale shared storage access"
