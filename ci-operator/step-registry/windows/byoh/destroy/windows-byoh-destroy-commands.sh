#!/bin/bash
set -o nounset
set -o pipefail

echo "=== Windows BYOH Cleanup ==="

# Debug: Print environment variables
echo "DEBUG: SHARED_DIR=${SHARED_DIR}"
echo "DEBUG: CLUSTER_PROFILE_DIR=${CLUSTER_PROFILE_DIR}"
echo "DEBUG: ARTIFACT_DIR=${ARTIFACT_DIR:-not set}"

# Test: Check if SHARED_DIR marker file exists (written by provision)
echo "Testing if SHARED_DIR is shared between steps..."
if [[ -f "${SHARED_DIR}/test-shared-dir-marker.txt" ]]; then
    echo "✓ SHARED_DIR IS SHARED - marker file found: $(cat "${SHARED_DIR}/test-shared-dir-marker.txt")"
else
    echo "✗ SHARED_DIR NOT SHARED - marker file not found"
fi
shopt -s nullglob
files=("${SHARED_DIR}"/*test-shared* "${SHARED_DIR}"/*byoh*)
if [[ ${#files[@]} -gt 0 ]]; then
    for file in "${files[@]}"; do
        echo "Found: $(basename "$file")"
    done
else
    echo "No test files found in SHARED_DIR"
fi

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

# Extract terraform state from SHARED_DIR tarball
if [[ -f "${SHARED_DIR}/terraform_byoh_state.tar.gz" ]]; then
    echo "Extracting terraform state from ${SHARED_DIR}/terraform_byoh_state.tar.gz..."
    tar -xzf "${SHARED_DIR}/terraform_byoh_state.tar.gz" -C "${ARTIFACT_DIR}"
    echo "✓ Terraform state extracted to ${ARTIFACT_DIR}/terraform_byoh/"
else
    echo "ERROR: Terraform state tarball not found at ${SHARED_DIR}/terraform_byoh_state.tar.gz"
    echo "Destroy step requires terraform state created by provision step"
    exit 1
fi

export BYOH_TMP_DIR="${ARTIFACT_DIR}/terraform_byoh/"

# Extract SSH public key from cluster profile (required by byoh.sh even for destroy)
if [[ -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
    WINC_SSH_PUBLIC_KEY=$(cat "${CLUSTER_PROFILE_DIR}/ssh-publickey")
    export WINC_SSH_PUBLIC_KEY
    echo "✓ SSH public key loaded from cluster profile"
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
WORK_DIR="/usr/local/share/byoh-provisioner"
echo "Using provisioner directory: ${WORK_DIR}"

# Detect platform
PLATFORM=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.type}" | tr '[:upper:]' '[:lower:]' 2>/dev/null || echo "unknown")
echo "Platform detected: ${PLATFORM}"

# Verify byoh.sh is available
if ! command -v byoh.sh &> /dev/null; then
    echo "ERROR: byoh.sh not found in terraform-windows-provisioner image"
    exit 1
fi

cd "${WORK_DIR}" || exit 1

# Verify Terraform state exists
TERRAFORM_STATE_FILE="${BYOH_TMP_DIR}${PLATFORM}/terraform.tfstate"
if [[ -f "${TERRAFORM_STATE_FILE}" ]]; then
    echo "✓ Terraform state found at ${TERRAFORM_STATE_FILE}"
else
    echo "ERROR: Terraform state not found at ${TERRAFORM_STATE_FILE}"
    echo "Expected location: ${TERRAFORM_STATE_FILE}"
    echo "Provision step should have created this file in ARTIFACT_DIR"
    exit 1
fi

# Destroy Windows nodes using Terraform
# NOTE: Must pass same arguments as provision step to find correct terraform state directory
# Arguments: action, instance_name, num_workers, folder_suffix, windows_version
echo "Destroying Windows BYOH nodes via Terraform..."
./byoh.sh destroy "${BYOH_INSTANCE_NAME}" "${BYOH_NUM_WORKERS}" "" "${BYOH_WINDOWS_VERSION}"

echo "✓ Windows BYOH cleanup completed"
