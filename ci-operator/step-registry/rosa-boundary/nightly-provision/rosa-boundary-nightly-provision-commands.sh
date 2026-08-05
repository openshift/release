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
if [[ -n "${AWS_CONFIG_FILE:-}" ]] && [[ -r "${AWS_CONFIG_FILE}" ]]; then
  echo "AWS credential file: ${AWS_CONFIG_FILE}"
  echo "File size: $(wc -c < "${AWS_CONFIG_FILE}") bytes"
  echo "Section headers:"
  grep '^\[' "${AWS_CONFIG_FILE}" || echo "  (no section headers found)"
  echo "Key names present:"
  grep -oE '^[a-z_]+' "${AWS_CONFIG_FILE}" || echo "  (no keys found)"
  echo "All mount contents:"
  ls -la "$(dirname "${AWS_CONFIG_FILE}")"

  export AWS_SHARED_CREDENTIALS_FILE="${AWS_CONFIG_FILE}"
  echo "AWS credentials configured via: ${AWS_SHARED_CREDENTIALS_FILE}"
else
  echo "ERROR: AWS_CONFIG_FILE not set or not readable: ${AWS_CONFIG_FILE:-not set}"
  exit 1
fi

# Default to us-east-1 if no region specified
export AWS_REGION="${AWS_REGION:-us-east-1}"

echo "Using AWS region: ${AWS_REGION}"

# Deploy network infrastructure first
echo "Deploying network infrastructure..."
cd deploy/network/

# Disable tracing for terraform operations (security best practice)
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

/tmp/terraform init
/tmp/terraform plan
/tmp/terraform apply -auto-approve

# Restore tracing temporarily for output operations
$WAS_TRACING && set -x

# Save network outputs
/tmp/terraform output -json > "${SHARED_DIR}/rosa-boundary-network-outputs.json"
echo "Network infrastructure provisioned successfully"

# Deploy regional infrastructure
echo "Deploying regional infrastructure..."
cd ../regional/

# Extract network outputs for regional module
VPC_ID=$(jq -r '.vpc_id.value' "${SHARED_DIR}/rosa-boundary-network-outputs.json")
SUBNET_IDS=$(jq -r '.private_subnet_ids.value | @json' "${SHARED_DIR}/rosa-boundary-network-outputs.json")

# Set placeholder values for application variables (CI testing only)
# These satisfy Terraform validation but aren't used by infrastructure-only e2e tests
export TF_VAR_vpc_id="${VPC_ID}"
export TF_VAR_subnet_ids="${SUBNET_IDS}"
export TF_VAR_container_image="quay.io/openshift-online/rosa-boundary:latest"
export TF_VAR_keycloak_issuer_url="https://auth.redhat.com/auth/realms/EmployeeIDP"
export TF_VAR_keycloak_thumbprint="0000000000000000000000000000000000000000"
export TF_VAR_required_groups='["nightly-e2e"]'

# Debug: Show that variables are set
echo "Terraform variables set:"
echo "  TF_VAR_vpc_id=${TF_VAR_vpc_id}"
echo "  TF_VAR_subnet_ids=${TF_VAR_subnet_ids}"
echo "  TF_VAR_container_image=${TF_VAR_container_image}"
echo "  TF_VAR_required_groups=${TF_VAR_required_groups}"

# Disable tracing again for terraform
set +x

/tmp/terraform init
/tmp/terraform plan
/tmp/terraform apply -auto-approve

# Save regional outputs
/tmp/terraform output -json > "${SHARED_DIR}/rosa-boundary-regional-outputs.json"
echo "Regional infrastructure provisioned successfully"

# Restore tracing
$WAS_TRACING && set -x

echo "Infrastructure provisioning complete"
