#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

umask 077

echo "=== Windows BYOH Cleanup ==="

# Read instance name saved by provision step (from SHARED_DIR)
if [[ -f "${SHARED_DIR}/byoh_instance_name.txt" ]]; then
    BYOH_INSTANCE_NAME=$(cat "${SHARED_DIR}/byoh_instance_name.txt")
    echo "Read instance name from provision step: ${BYOH_INSTANCE_NAME}"
else
    # Fallback to default if file doesn't exist (shouldn't happen in normal flow)
    BYOH_INSTANCE_NAME="${BYOH_INSTANCE_NAME:-byoh-winc}"
    echo "WARNING: Instance name file not found, using default: ${BYOH_INSTANCE_NAME}"
fi
export BYOH_INSTANCE_NAME
export BYOH_NUM_WORKERS="${BYOH_NUM_WORKERS:-2}"
export BYOH_WINDOWS_VERSION="${BYOH_WINDOWS_VERSION:-2022}"

# Extract terraform state + config from SHARED_DIR tarball
# Auto-detect which platform tarball exists (aws, azure, gcp, vsphere, nutanix, none)
PLATFORM=""
for p in aws azure gcp vsphere nutanix none; do
    if [[ -f "${SHARED_DIR}/terraform_byoh_${p}.tar" ]]; then
        PLATFORM="${p}"
        echo "Detected terraform platform: ${PLATFORM}"
        break
    fi
done
if [[ -z "${PLATFORM}" ]]; then
    echo "ERROR: No terraform tarball found in ${SHARED_DIR}/ (checked: aws, azure, gcp, vsphere, nutanix, none)"
    exit 1
fi

# Keep extracted state in protected shared storage. Terraform state can contain
# credentials and must never be copied to the public artifact directory.
export BYOH_TMP_DIR="${SHARED_DIR}/terraform_byoh_destroy/"
rm -rf "${BYOH_TMP_DIR}"
mkdir -p "${BYOH_TMP_DIR}${PLATFORM}"

cleanup_state() {
    local status=$?
    trap - EXIT
    rm -rf "${BYOH_TMP_DIR}" || true
    exit "${status}"
}
trap cleanup_state EXIT

if [[ -f "${SHARED_DIR}/terraform_byoh_${PLATFORM}.tar" ]]; then
    echo "Extracting terraform files from ${SHARED_DIR}/terraform_byoh_${PLATFORM}.tar..."
    tar -xf "${SHARED_DIR}/terraform_byoh_${PLATFORM}.tar" -C "${BYOH_TMP_DIR}${PLATFORM}"
    echo "Terraform cleanup state extracted in protected shared storage"
else
    echo "ERROR: Terraform tarball not found at ${SHARED_DIR}/terraform_byoh_${PLATFORM}.tar"
    echo "Destroy step requires terraform files created by provision step"
    exit 1
fi

# Extract SSH public key from cluster profile (required by byoh.sh even for destroy)
if [[ -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
    WINC_SSH_PUBLIC_KEY=$(cat "${CLUSTER_PROFILE_DIR}/ssh-publickey")
    export WINC_SSH_PUBLIC_KEY
    echo "SSH public key loaded from cluster profile"
fi

# Setup cloud credentials from cluster profile (same as provision)
if [[ -f "${CLUSTER_PROFILE_DIR}/.awscred" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    export AWS_PROFILE="default"
fi

if [[ -f "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json" ]]; then
    ARM_CLIENT_ID=$(jq -r .clientId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    ARM_CLIENT_SECRET=$(jq -r .clientSecret "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    ARM_SUBSCRIPTION_ID=$(jq -r .subscriptionId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    ARM_TENANT_ID=$(jq -r .tenantId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    export ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID ARM_TENANT_ID
fi

if [[ -f "${CLUSTER_PROFILE_DIR}/gce.json" ]]; then
    GOOGLE_CREDENTIALS=$(cat "${CLUSTER_PROFILE_DIR}/gce.json")
    export GOOGLE_CREDENTIALS
fi

# Use provisioner directory from image (scripts are pre-installed)
WORK_DIR="${BYOH_PROVISIONER_DIR:-/usr/local/share/byoh-provisioner}"
echo "Using provisioner directory: ${WORK_DIR}"


# Verify byoh.sh is available
if [[ ! -x "${WORK_DIR}/byoh.sh" ]]; then
    echo "ERROR: byoh.sh not found in terraform-windows-provisioner image"
    exit 1
fi

cd "${WORK_DIR}" || exit 1

# Verify Terraform state exists
TERRAFORM_STATE_FILE="${BYOH_TMP_DIR}${PLATFORM}/terraform.tfstate"
if [[ -f "${TERRAFORM_STATE_FILE}" ]]; then
    echo "Terraform state found at ${TERRAFORM_STATE_FILE}"
else
    echo "ERROR: Terraform state not found at ${TERRAFORM_STATE_FILE}"
    echo "Expected location: ${TERRAFORM_STATE_FILE}"
    echo "Provision step should have saved this file in protected shared storage"
    exit 1
fi

# Initialize Terraform providers before destroy
# Destroy runs in new container so .terraform/ doesn't exist
echo "Initializing Terraform providers..."
cd "${BYOH_TMP_DIR}${PLATFORM}" || exit 1
if [[ -d .terraform ]]; then
    echo "Removing existing .terraform directory..."
    rm -rf .terraform
fi
terraform init -input=false -no-color
echo "Terraform initialized"

cd "${WORK_DIR}" || exit 1

# Destroy Windows nodes using Terraform
# NOTE: Must pass same arguments as provision step to find correct terraform state directory
# Arguments: action, instance_name, num_workers, folder_suffix, windows_version
echo "Destroying Windows BYOH nodes via Terraform..."
./byoh.sh destroy "${BYOH_INSTANCE_NAME}" "${BYOH_NUM_WORKERS}" "" "${BYOH_WINDOWS_VERSION}"

echo "Windows BYOH cleanup completed"
