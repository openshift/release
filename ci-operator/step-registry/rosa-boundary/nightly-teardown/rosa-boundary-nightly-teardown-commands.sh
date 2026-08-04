#!/bin/bash

set -euo pipefail

# Install terraform
TERRAFORM_VERSION="1.9.5"
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

# AWS credentials come from mounted secret via AWS_CONFIG_FILE env var
# Default to us-east-1 if no region specified
export AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Using AWS region: ${AWS_REGION}"

# Disable tracing for terraform operations
set +x

# Track teardown failures
TEARDOWN_FAILED=0

# Destroy in reverse order - regional first, then network
echo "Destroying regional infrastructure..."
cd deploy/regional/
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
