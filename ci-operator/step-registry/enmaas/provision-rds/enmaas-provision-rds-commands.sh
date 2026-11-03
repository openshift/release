#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

echo "Provisioning RDS PostgreSQL instance for EnMaaS..."

# Generate a unique instance identifier from the build
INSTANCE_ID="enmaas-ci-${BUILD_ID:0:8}"
SUBNET_GROUP_NAME="${INSTANCE_ID}-subnet-group"

echo "Instance identifier: ${INSTANCE_ID}"

# Read VPC information written by the aws-provision-vpc-shared step
if [[ ! -f "${SHARED_DIR}/vpc_id" ]]; then
  echo "ERROR: ${SHARED_DIR}/vpc_id not found. The VPC provisioning step must run first."
  exit 1
fi
VPC_ID=$(cat "${SHARED_DIR}/vpc_id")
echo "VPC ID: ${VPC_ID}"

# Read private subnet IDs (stored as JSON array with single quotes by vpc-shared step)
if [[ ! -f "${SHARED_DIR}/private_subnet_ids" ]]; then
  echo "ERROR: ${SHARED_DIR}/private_subnet_ids not found."
  exit 1
fi
# The vpc-shared step writes subnets as ['subnet-xxx','subnet-yyy','subnet-zzz']
# Convert single quotes to double quotes for jq, then extract as space-separated list
RAW_SUBNETS=$(cat "${SHARED_DIR}/private_subnet_ids")
PRIVATE_SUBNETS=$(echo "${RAW_SUBNETS}" | tr "'" '"' | jq -r '.[]')
echo "Private subnets: ${PRIVATE_SUBNETS}"

# Determine the AWS region from the cluster profile or default
REGION="${LEASED_RESOURCE:-us-east-2}"

# Create DB subnet group
echo "Creating DB subnet group: ${SUBNET_GROUP_NAME}..."
aws rds create-db-subnet-group \
  --db-subnet-group-name "${SUBNET_GROUP_NAME}" \
  --db-subnet-group-description "EnMaaS CI RDS subnet group for ${INSTANCE_ID}" \
  --subnet-ids ${PRIVATE_SUBNETS} \
  --region "${REGION}" \
  --tags Key=EnMaaS,Value=ci Key=BuildID,Value="${BUILD_ID}"
echo "DB subnet group created."
echo "${SUBNET_GROUP_NAME}" > "${SHARED_DIR}/rds-subnet-group"

# Get VPC CIDR block for security group rule
VPC_CIDR=$(aws ec2 describe-vpcs \
  --vpc-ids "${VPC_ID}" \
  --region "${REGION}" \
  --query 'Vpcs[0].CidrBlock' \
  --output text)
echo "VPC CIDR: ${VPC_CIDR}"

# Create security group for RDS
echo "Creating security group for RDS..."
SG_ID=$(aws ec2 create-security-group \
  --group-name "${INSTANCE_ID}-rds-sg" \
  --description "EnMaaS CI RDS security group for ${INSTANCE_ID}" \
  --vpc-id "${VPC_ID}" \
  --region "${REGION}" \
  --query 'GroupId' \
  --output text)
echo "Security group created: ${SG_ID}"
echo "${SG_ID}" > "${SHARED_DIR}/rds-security-group-id"

# Tag the security group
aws ec2 create-tags \
  --resources "${SG_ID}" \
  --region "${REGION}" \
  --tags Key=Name,Value="${INSTANCE_ID}-rds-sg" Key=EnMaaS,Value=ci Key=BuildID,Value="${BUILD_ID}"

# Allow inbound PostgreSQL traffic from VPC CIDR
aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --protocol tcp \
  --port 5432 \
  --cidr "${VPC_CIDR}" \
  --region "${REGION}"
echo "Inbound rule added: TCP 5432 from ${VPC_CIDR}"

# Generate a random password for the RDS master user
# Disable tracing due to password handling
RDS_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)

# Create the RDS instance
echo "${INSTANCE_ID}" > "${SHARED_DIR}/rds-instance-id"
echo "Creating RDS instance: ${INSTANCE_ID}..."
aws rds create-db-instance \
  --db-instance-identifier "${INSTANCE_ID}" \
  --db-instance-class "${RDS_INSTANCE_CLASS}" \
  --engine postgres \
  --engine-version "${RDS_ENGINE_VERSION}" \
  --allocated-storage "${RDS_ALLOCATED_STORAGE}" \
  --master-username "${RDS_MASTER_USERNAME}" \
  --master-user-password "${RDS_PASSWORD}" \
  --db-subnet-group-name "${SUBNET_GROUP_NAME}" \
  --vpc-security-group-ids "${SG_ID}" \
  --no-publicly-accessible \
  --backup-retention-period 0 \
  --db-name "${RDS_DB_NAME}" \
  --region "${REGION}" \
  --tags Key=EnMaaS,Value=ci Key=BuildID,Value="${BUILD_ID}"
echo "RDS instance creation initiated."

# Wait for the instance to become available
echo "Waiting for RDS instance to become available (this may take several minutes)..."
aws rds wait db-instance-available \
  --db-instance-identifier "${INSTANCE_ID}" \
  --region "${REGION}"
echo "RDS instance is available."

# Get the endpoint information
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "${INSTANCE_ID}" \
  --region "${REGION}" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)
RDS_PORT=$(aws rds describe-db-instances \
  --db-instance-identifier "${INSTANCE_ID}" \
  --region "${REGION}" \
  --query 'DBInstances[0].Endpoint.Port' \
  --output text)

echo "RDS endpoint: ${RDS_ENDPOINT}:${RDS_PORT}"

# Write connection details to SHARED_DIR for downstream steps
echo "${RDS_ENDPOINT}" > "${SHARED_DIR}/rds-endpoint"
echo "${RDS_PORT}" > "${SHARED_DIR}/rds-port"
echo "${RDS_MASTER_USERNAME}" > "${SHARED_DIR}/rds-username"
echo "${RDS_DB_NAME}" > "${SHARED_DIR}/rds-dbname"

# Disable tracing due to password handling
echo "${RDS_PASSWORD}" > "${SHARED_DIR}/rds-password"

echo ""
echo "=== RDS Provisioning Summary ==="
echo "Instance ID:    ${INSTANCE_ID}"
echo "Endpoint:       ${RDS_ENDPOINT}"
echo "Port:           ${RDS_PORT}"
echo "Database:       ${RDS_DB_NAME}"
echo "Username:       ${RDS_MASTER_USERNAME}"
echo "Instance Class: ${RDS_INSTANCE_CLASS}"
echo "Engine:         PostgreSQL ${RDS_ENGINE_VERSION}"
echo "Storage:        ${RDS_ALLOCATED_STORAGE} GB"
echo "Subnet Group:   ${SUBNET_GROUP_NAME}"
echo "Security Group: ${SG_ID}"
echo "================================"
