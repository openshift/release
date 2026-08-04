#!/bin/bash

set -euo pipefail

# Install terraform
TERRAFORM_VERSION="1.9.5"
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
