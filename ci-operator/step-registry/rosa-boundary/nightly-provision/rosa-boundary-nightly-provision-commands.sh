#!/bin/bash

set -euo pipefail

# Install terraform
TERRAFORM_VERSION="1.15.8"
echo "Installing Terraform ${TERRAFORM_VERSION}..."
curl -L -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
unzip /tmp/terraform.zip -d /tmp/
chmod +x /tmp/terraform

# Install AWS CLI v2
echo "Installing AWS CLI v2..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
unzip -q /tmp/awscliv2.zip -d /tmp/
/tmp/aws/install --install-dir /tmp/aws-cli --bin-dir /tmp/bin
export PATH="/tmp/bin:${PATH}"

# AWS credentials come from mounted secret via AWS_CONFIG_FILE env var
# Extract credentials from AWS config file for Terraform
if [[ -n "${AWS_CONFIG_FILE:-}" ]] && [[ -r "${AWS_CONFIG_FILE}" ]]; then
  echo "Extracting AWS credentials from ${AWS_CONFIG_FILE}"

  # Try simple key=value format first (like .awscred files)
  # Format: aws_access_key_id=VALUE
  AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id" "${AWS_CONFIG_FILE}" | cut -d'=' -f2 | tr -d ' ')
  AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key" "${AWS_CONFIG_FILE}" | cut -d'=' -f2 | tr -d ' ')

  # If empty, try AWS CLI config format with [default] section
  if [[ -z "${AWS_ACCESS_KEY_ID}" ]]; then
    AWS_ACCESS_KEY_ID=$(grep -A10 "\[default\]" "${AWS_CONFIG_FILE}" | grep "aws_access_key_id" | cut -d'=' -f2 | tr -d ' ')
    AWS_SECRET_ACCESS_KEY=$(grep -A10 "\[default\]" "${AWS_CONFIG_FILE}" | grep "aws_secret_access_key" | cut -d'=' -f2 | tr -d ' ')
  fi

  if [[ -z "${AWS_ACCESS_KEY_ID}" ]] || [[ -z "${AWS_SECRET_ACCESS_KEY}" ]]; then
    echo "ERROR: Failed to extract AWS credentials from config file"
    echo "Config file format not recognized. Expected either:"
    echo "  1. Simple: aws_access_key_id=VALUE"
    echo "  2. Profile: [default] section with aws_access_key_id = VALUE"
    exit 1
  fi

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  echo "AWS credentials extracted successfully"
else
  echo "ERROR: AWS_CONFIG_FILE not set or not readable: ${AWS_CONFIG_FILE:-not set}"
  exit 1
fi

# Default to us-east-1 if no region specified
export AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Using AWS region: ${AWS_REGION}"

# Disable tracing for terraform operations (security best practice)
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

# Deploy network infrastructure first
echo "Deploying network infrastructure..."
cd deploy/network/
/tmp/terraform init
/tmp/terraform plan
/tmp/terraform apply -auto-approve

# Save network outputs
/tmp/terraform output -json > "${SHARED_DIR}/rosa-boundary-network-outputs.json"
echo "Network infrastructure provisioned successfully"

# Deploy regional infrastructure
echo "Deploying regional infrastructure..."
cd ../regional/
/tmp/terraform init
/tmp/terraform plan
/tmp/terraform apply -auto-approve

# Save regional outputs
/tmp/terraform output -json > "${SHARED_DIR}/rosa-boundary-regional-outputs.json"
echo "Regional infrastructure provisioned successfully"

# Restore tracing
$WAS_TRACING && set -x

echo "Infrastructure provisioning complete"
