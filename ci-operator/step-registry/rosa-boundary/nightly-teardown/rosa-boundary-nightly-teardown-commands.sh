#!/bin/bash

set -euo pipefail

# Install terraform (same as provision)
TERRAFORM_VERSION="1.9.5"
echo "Installing Terraform ${TERRAFORM_VERSION}..."
curl -L -o /tmp/terraform.zip "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip"
unzip /tmp/terraform.zip -d /tmp/
chmod +x /tmp/terraform

# AWS credentials come from mounted secret via AWS_CONFIG_FILE env var
# Default to us-east-1 if no region specified
export AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Using AWS region: ${AWS_REGION}"

# Disable tracing for terraform operations
set +x

# Destroy in reverse order - regional first, then network
echo "Destroying regional infrastructure..."
cd deploy/regional/
/tmp/terraform init || echo "Regional terraform init failed, continuing..."
/tmp/terraform destroy -auto-approve || echo "Regional destroy failed, continuing..."

echo "Destroying network infrastructure..."
cd ../network/
/tmp/terraform init || echo "Network terraform init failed, continuing..."
/tmp/terraform destroy -auto-approve || echo "Network destroy failed, continuing..."

echo "Infrastructure teardown complete"
