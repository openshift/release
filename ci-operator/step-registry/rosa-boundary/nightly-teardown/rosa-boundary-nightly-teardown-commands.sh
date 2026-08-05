#!/bin/bash

set -euo pipefail

# Install terraform
TERRAFORM_VERSION="1.15.8"
echo "Installing Terraform ${TERRAFORM_VERSION}..."
curl -L -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
unzip /tmp/terraform.zip -d /tmp/
chmod +x /tmp/terraform

# Install AWS CLI v2 (needed for terraform AWS provider)
echo "Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install --install-dir /tmp/aws-cli --bin-dir /tmp/bin
export PATH="/tmp/bin:${PATH}"

# AWS credentials from cluster_profile: aws
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Default to us-east-1 if no region specified
export AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Using AWS region: ${AWS_REGION}"

# Discover AWS account ID for Terraform's allowed_account_ids guard
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export TF_VAR_aws_account_id="${AWS_ACCOUNT_ID}"
echo "AWS account ID: ${AWS_ACCOUNT_ID}"

# Disable tracing for terraform operations
set +x

# Track teardown failures
TEARDOWN_FAILED=0

# Destroy in reverse order - regional first, then network
echo "Destroying regional infrastructure..."
cd deploy/regional/

# Set Terraform variables for destroy (required even though values come from state)
# Try to read from provision outputs if available, otherwise use placeholders
if [[ -f "${SHARED_DIR}/rosa-boundary-network-outputs.json" ]]; then
  echo "Reading network outputs from provision step..."
  VPC_ID=$(jq -r '.vpc_id.value // "vpc-placeholder"' "${SHARED_DIR}/rosa-boundary-network-outputs.json")
  SUBNET_IDS=$(jq -r '.private_subnet_ids.value // [] | @json' "${SHARED_DIR}/rosa-boundary-network-outputs.json")
else
  echo "Network outputs not found, using placeholders for variable validation..."
  VPC_ID="vpc-placeholder"
  SUBNET_IDS='["subnet-placeholder"]'
fi

# Export all required variables (Terraform requires them even for destroy)
export TF_VAR_vpc_id="${VPC_ID}"
export TF_VAR_subnet_ids="${SUBNET_IDS}"
export TF_VAR_container_image="quay.io/openshift-online/rosa-boundary:placeholder"
export TF_VAR_keycloak_issuer_url="https://placeholder.example.com"
export TF_VAR_keycloak_thumbprint="0000000000000000000000000000000000000000"
export TF_VAR_required_groups='["placeholder"]'

echo "Terraform variables set for destroy operation"

if ! /tmp/terraform init; then
  echo "Regional terraform init failed, continuing..."
  TEARDOWN_FAILED=1
fi
if ! /tmp/terraform destroy -auto-approve; then
  echo "Regional destroy failed, continuing..."
  TEARDOWN_FAILED=1
fi

echo "Destroying network infrastructure..."
cd ../network/
if ! /tmp/terraform init; then
  echo "Network terraform init failed, continuing..."
  TEARDOWN_FAILED=1
fi
if ! /tmp/terraform destroy -auto-approve; then
  echo "Network destroy failed, continuing..."
  TEARDOWN_FAILED=1
fi

if [[ ${TEARDOWN_FAILED} -eq 1 ]]; then
  echo "Infrastructure teardown completed with failures"
  exit 1
else
  echo "Infrastructure teardown completed successfully"
fi
