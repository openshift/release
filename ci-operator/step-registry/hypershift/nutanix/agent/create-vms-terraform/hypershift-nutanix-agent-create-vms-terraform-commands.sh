#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Create Nutanix VMs using Terraform for HyperShift ************"

# Source Nutanix context from IPI workflow
if [[ -f "${SHARED_DIR}/nutanix_context.sh" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Loading Nutanix context..."
    source "${SHARED_DIR}/nutanix_context.sh"
else
    echo "$(date -u --rfc-3339=seconds) - ERROR: nutanix_context.sh not found"
    exit 1
fi

# Get hosted cluster name and ISO path
CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
ISO_LOCAL_PATH=$(cat "${SHARED_DIR}/iso-local-path.txt")
NUM_WORKERS="${NUM_EXTRA_WORKERS:-2}"

echo "$(date -u --rfc-3339=seconds) - Cluster name: ${CLUSTER_NAME}"
echo "$(date -u --rfc-3339=seconds) - ISO path: ${ISO_LOCAL_PATH}"
echo "$(date -u --rfc-3339=seconds) - Number of workers: ${NUM_WORKERS}"

# Prepare Terraform working directory
TERRAFORM_DIR="${SHARED_DIR}/terraform-nutanix"
mkdir -p "${TERRAFORM_DIR}"

# Copy Terraform configuration from assisted-test-infra
# The assisted-test-infra-internal image contains these files at:
# /home/assisted-test-infra/terraform_files/nutanix/
echo "$(date -u --rfc-3339=seconds) - Copying Terraform configuration..."
cp -r /home/assisted-test-infra/terraform_files/nutanix/* "${TERRAFORM_DIR}/"

# Extract Nutanix cluster and subnet names
NUTANIX_CLUSTER_NAME="${PE_NAME//\"/}"  # Remove quotes
SUBNET_NAME="${LEASED_RESOURCE}"

echo "$(date -u --rfc-3339=seconds) - Nutanix cluster: ${NUTANIX_CLUSTER_NAME}"
echo "$(date -u --rfc-3339=seconds) - Subnet: ${SUBNET_NAME}"

# Create Terraform variables file
echo "$(date -u --rfc-3339=seconds) - Creating terraform.tfvars..."
cat > "${TERRAFORM_DIR}/terraform.tfvars" <<EOF
# Nutanix credentials
nutanix_username = "${NUTANIX_USERNAME}"
nutanix_password = "${NUTANIX_PASSWORD}"
nutanix_endpoint = "${NUTANIX_HOST}"
nutanix_port     = ${NUTANIX_PORT}
nutanix_cluster  = "${NUTANIX_CLUSTER_NAME}"
nutanix_subnet   = "${SUBNET_NAME}"

# Cluster information
cluster_name      = "${CLUSTER_NAME}"
iso_download_path = "${ISO_LOCAL_PATH}"

# HyperShift only needs workers (no masters)
masters_count = 0
workers_count = ${NUM_WORKERS}

# Worker VM specifications
worker_memory = 16384              # 16GB
worker_disk   = 107374182400       # 100GB
worker_vcpu   = 4
nutanix_control_plane_cores_per_socket = 2

# Master specs (required by variables but not used since masters_count=0)
master_memory = 16384
master_disk   = 107374182400
master_vcpu   = 4
EOF

cd "${TERRAFORM_DIR}"

# Initialize Terraform
echo "$(date -u --rfc-3339=seconds) - Initializing Terraform..."
terraform init -input=false

# Validate configuration
echo "$(date -u --rfc-3339=seconds) - Validating Terraform configuration..."
terraform validate

# Apply Terraform configuration to create VMs
echo "$(date -u --rfc-3339=seconds) - Creating ${NUM_WORKERS} worker VMs with Terraform..."
terraform apply -auto-approve -input=false

# Get created VM UUIDs
echo "$(date -u --rfc-3339=seconds) - Getting created VM UUIDs..."
WORKER_VM_UUIDS=$(terraform output -json worker_ids 2>/dev/null | jq -r '.[]' | tr '\n' ',' | sed 's/,$//')

if [ -z "${WORKER_VM_UUIDS}" ]; then
    echo "$(date -u --rfc-3339=seconds) - WARNING: No worker VM UUIDs returned by Terraform"
else
    echo "$(date -u --rfc-3339=seconds) - Created worker VMs: ${WORKER_VM_UUIDS}"
    echo "${WORKER_VM_UUIDS}" > "${SHARED_DIR}/worker-vm-uuids.txt"
fi

# Save Terraform state for cleanup
echo "$(date -u --rfc-3339=seconds) - Saving Terraform state..."
tar -czf "${SHARED_DIR}/terraform-state.tgz" -C "${TERRAFORM_DIR}" .

echo "$(date -u --rfc-3339=seconds) - Terraform VM creation completed successfully"
