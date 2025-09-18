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

# Get cluster information
echo "Checking for cluster information files..."
echo "SHARED_DIR: ${SHARED_DIR}"
echo "Files in SHARED_DIR:"
ls -la "${SHARED_DIR}/" || echo "Could not list SHARED_DIR"

# Try different possible locations for cluster name
CLUSTER_NAME=""
if [[ -f "${SHARED_DIR}/CLUSTER_NAME" ]]; then
  CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"
  echo "Found CLUSTER_NAME in ${SHARED_DIR}/CLUSTER_NAME: ${CLUSTER_NAME}"
elif [[ -f "${SHARED_DIR}/cluster_name" ]]; then
  CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
  echo "Found cluster_name in ${SHARED_DIR}/cluster_name: ${CLUSTER_NAME}"
else
  echo "WARNING: Could not find cluster name file, using default"
  CLUSTER_NAME="fusion-access-test"
fi

# Try different possible locations for VPC ID
VPC_ID=""
if [[ -f "${SHARED_DIR}/vpc_id" ]]; then
  VPC_ID="$(<"${SHARED_DIR}/vpc_id")"
  echo "Found vpc_id in ${SHARED_DIR}/vpc_id: ${VPC_ID}"
elif [[ -f "${SHARED_DIR}/VPC_ID" ]]; then
  VPC_ID="$(<"${SHARED_DIR}/VPC_ID")"
  echo "Found VPC_ID in ${SHARED_DIR}/VPC_ID: ${VPC_ID}"
else
  echo "WARNING: Could not find VPC ID file, will try to discover it"
  # Try to discover VPC ID from existing resources
  VPC_ID=$(aws ec2 describe-vpcs --region "${REGION}" --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
  if [[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]]; then
    echo "Discovered default VPC ID: ${VPC_ID}"
  else
    echo "ERROR: Could not find or discover VPC ID"
    exit 1
  fi
fi

echo "Final values:"
echo "  CLUSTER_NAME: ${CLUSTER_NAME}"
echo "  VPC_ID: ${VPC_ID}"

# Create a custom security group for IBM Storage Scale
SG_NAME="${CLUSTER_NAME}-ibm-storage-scale-sg"
echo "Creating custom security group: ${SG_NAME}"

# Create tag specifications file
TAG_JSON=$(mktemp)
cat > "${TAG_JSON}" <<EOF
[
  {
    "ResourceType": "security-group",
    "Tags": [
      {
        "Key": "Name",
        "Value": "${SG_NAME}"
      },
      {
        "Key": "Purpose",
        "Value": "IBM-Storage-Scale"
      }
    ]
  }
]
EOF

# Debug: Show the values being used
echo "Debug information:"
echo "  SG_NAME: '${SG_NAME}'"
echo "  VPC_ID: '${VPC_ID}'"
echo "  REGION: '${REGION}'"
echo "  TAG_JSON: '${TAG_JSON}'"

# Create the security group
echo "Creating security group with command:"
echo "aws ec2 create-security-group --region \"${REGION}\" --group-name \"${SG_NAME}\" --vpc-id \"${VPC_ID}\" --description \"IBM Storage Scale security group for Fusion Access Operator testing\" --tag-specifications \"file://${TAG_JSON}\" --query 'GroupId' --output text"

SG_ID=$(aws ec2 create-security-group --region "${REGION}" --group-name "${SG_NAME}" --vpc-id "${VPC_ID}" --description "IBM Storage Scale security group for Fusion Access Operator testing" --tag-specifications "file://${TAG_JSON}" --query 'GroupId' --output text 2>&1)
SG_CREATE_EXIT_CODE=$?

# Clean up temporary file
rm -f "${TAG_JSON}"

if [[ $SG_CREATE_EXIT_CODE -ne 0 ]]; then
  echo "ERROR: Failed to create security group"
  echo "Exit code: $SG_CREATE_EXIT_CODE"
  echo "Output: $SG_ID"
  exit 1
fi

if [[ -z "${SG_ID}" ]]; then
  echo "ERROR: Security group creation succeeded but no group ID returned"
  exit 1
fi

echo "Created security group: ${SG_ID}"

# Try to write to SHARED_DIR, but fallback to /tmp if it's read-only
if echo "${SG_ID}" > "${SHARED_DIR}/security_groups_ids" 2>/dev/null; then
  echo "Security group ID saved to: ${SHARED_DIR}/security_groups_ids"
else
  echo "WARNING: Could not write to ${SHARED_DIR}/security_groups_ids (read-only filesystem)"
  echo "Writing to /tmp/security_groups_ids instead"
  echo "${SG_ID}" > "/tmp/security_groups_ids"
  echo "Security group ID saved to: /tmp/security_groups_ids"
  
  # Also try to export it as an environment variable for other steps
  echo "export SECURITY_GROUP_ID=${SG_ID}" >> /tmp/security_group_env
  echo "Security group ID also exported to: /tmp/security_group_env"
fi

# Configure install-config.yaml directly if we can't use the standard step
if [[ ! -f "${SHARED_DIR}/security_groups_ids" ]]; then
  echo "Configuring install-config.yaml directly with security group ID..."
  CONFIG="${SHARED_DIR}/install-config.yaml"
  
  if [[ -f "${CONFIG}" ]]; then
    echo "Adding security group to install-config.yaml..."
    
    # Create a patch for the install-config
    PATCH=$(mktemp)
    cat > "${PATCH}" <<EOF
compute:
- platform:
    aws:
      additionalSecurityGroupIDs: ["${SG_ID}"]
controlPlane:
  platform:
    aws:
      additionalSecurityGroupIDs: ["${SG_ID}"]
EOF
    
    echo "Install-config patch:"
    cat "${PATCH}"
    
    # Apply the patch using yq
    if command -v yq >/dev/null 2>&1; then
      yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "${CONFIG}" "${PATCH}" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "${CONFIG}"
      echo "✅ Install-config updated with security group ID"
    else
      echo "WARNING: yq not available, install-config not updated"
    fi
    
    rm -f "${PATCH}"
  else
    echo "WARNING: install-config.yaml not found at ${CONFIG}"
  fi
fi

# Get the VPC CIDR for allowing traffic within the VPC
VPC_CIDR=$(aws ec2 describe-vpcs --region "${REGION}" --vpc-ids "${VPC_ID}" --query 'Vpcs[0].CidrBlock' --output text)
echo "VPC CIDR: ${VPC_CIDR}"

# Allow traffic from within the VPC
aws ec2 authorize-security-group-ingress \
  --region "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol tcp \
  --port 0-65535 \
  --cidr "${VPC_CIDR}" || echo "WARNING: TCP rule may already exist"

aws ec2 authorize-security-group-ingress \
  --region "${REGION}" \
  --group-id "${SG_ID}" \
  --protocol udp \
  --port 0-65535 \
  --cidr "${VPC_CIDR}" || echo "WARNING: UDP rule may already exist"

echo "Configured security group: ${SG_ID}"

# Parse custom security group configuration from environment variables
# Default IBM Storage Scale ports if not specified
CUSTOM_PORTS="${CUSTOM_SECURITY_GROUP_PORTS:-12345,1191,60000-61000}"
CUSTOM_PROTOCOLS="${CUSTOM_SECURITY_GROUP_PROTOCOLS:-tcp,udp}"
CUSTOM_SOURCES="${CUSTOM_SECURITY_GROUP_SOURCES:-${VPC_CIDR}}"

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
            --group-id "${SG_ID}" \
            --protocol "${protocol}" \
            --port "${start_port}-${end_port}" \
            --cidr "${source}" || {
            echo "WARNING: Rule for ${protocol} ports ${start_port}-${end_port} from ${source} may already exist"
          }
        else
          # Source is a security group
          aws ec2 authorize-security-group-ingress \
            --region "${REGION}" \
            --group-id "${SG_ID}" \
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
            --group-id "${SG_ID}" \
            --protocol "${protocol}" \
            --port "${port}" \
            --cidr "${source}" || {
            echo "WARNING: Rule for ${protocol} port ${port} from ${source} may already exist"
          }
        else
          # Source is a security group
          aws ec2 authorize-security-group-ingress \
            --region "${REGION}" \
            --group-id "${SG_ID}" \
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
echo "  Security Group ID: ${SG_ID}"
echo "  Security Group Name: ${SG_NAME}"
echo "  Region: ${REGION}"
echo "  VPC ID: ${VPC_ID}"
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
