#!/bin/bash
set -o nounset
set -o pipefail

echo "=== Windows BYOH Cleanup ==="

# Debug: Print environment variables
echo "DEBUG: SHARED_DIR=${SHARED_DIR}"
echo "DEBUG: CLUSTER_PROFILE_DIR=${CLUSTER_PROFILE_DIR}"
echo "DEBUG: ARTIFACT_DIR=${ARTIFACT_DIR:-not set}"

# Read instance name saved by provision step (from ARTIFACT_DIR, not SHARED_DIR)
if [[ -f "${ARTIFACT_DIR}/byoh_instance_name.txt" ]]; then
    BYOH_INSTANCE_NAME=$(cat "${ARTIFACT_DIR}/byoh_instance_name.txt")
    echo "Read instance name from provision step: ${BYOH_INSTANCE_NAME}"
else
    # Fallback to default if file doesn't exist (shouldn't happen in normal flow)
    BYOH_INSTANCE_NAME="${BYOH_INSTANCE_NAME:-byoh-winc}"
    echo "WARNING: Instance name file not found, using default: ${BYOH_INSTANCE_NAME}"
fi
export BYOH_INSTANCE_NAME
export BYOH_NUM_WORKERS="${BYOH_NUM_WORKERS:-2}"
export BYOH_WINDOWS_VERSION="${BYOH_WINDOWS_VERSION:-2022}"
# Use ARTIFACT_DIR for terraform state (SHARED_DIR is wrong - it's the cluster-profile secret mount)
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
    # Authenticate gcloud for fallback cleanup
    gcloud auth activate-service-account --key-file="${CLUSTER_PROFILE_DIR}/gce.json" 2>/dev/null || echo "WARNING: Could not authenticate gcloud"
    # Extract and set project ID
    GCP_PROJECT=$(jq -r .project_id "${CLUSTER_PROFILE_DIR}/gce.json" 2>/dev/null || echo "")
    if [[ -n "${GCP_PROJECT}" ]]; then
        gcloud config set project "${GCP_PROJECT}" 2>/dev/null || echo "WARNING: Could not set gcloud project"
    fi
fi

# Use provisioner directory from image (scripts are pre-installed)
WORK_DIR="/usr/local/share/byoh-provisioner"
echo "Using provisioner directory: ${WORK_DIR}"

# Cloud CLI cleanup function (fallback when terraform fails or is unavailable)
cleanup_with_cloud_cli() {
    local platform="${1}"
    echo "Attempting to destroy BYOH instances directly using cloud CLI..."

    if [[ "${platform}" == "gcp" ]]; then
        if command -v gcloud &> /dev/null; then
            echo "Attempting GCP instance cleanup..."
            ZONE=$(gcloud compute instances list --filter="name~${BYOH_INSTANCE_NAME}" --format="value(zone)" --limit=1 2>/dev/null || echo "")
            if [[ -n "${ZONE}" ]]; then
                INSTANCES=$(gcloud compute instances list --filter="name~${BYOH_INSTANCE_NAME}" --format="value(name)" 2>/dev/null || echo "")
                if [[ -n "${INSTANCES}" ]]; then
                    echo "Deleting GCP instances: ${INSTANCES}"
                    echo "${INSTANCES}" | xargs -r gcloud compute instances delete --zone="${ZONE}" --quiet || echo "WARNING: GCP cleanup failed"
                else
                    echo "No GCP instances found matching ${BYOH_INSTANCE_NAME}"
                fi
            else
                echo "No zone found for instances matching ${BYOH_INSTANCE_NAME}"
            fi
        else
            echo "WARNING: gcloud CLI not available, cannot cleanup GCP instances"
        fi
    elif [[ "${platform}" == "aws" ]]; then
        if command -v aws &> /dev/null; then
            echo "Attempting AWS instance cleanup..."
            REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
            INSTANCE_IDS=$(aws ec2 describe-instances --region "${REGION}" --filters "Name=tag:Name,Values=${BYOH_INSTANCE_NAME}*" "Name=instance-state-name,Values=running,stopped" --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
            if [[ -n "${INSTANCE_IDS}" ]]; then
                echo "Deleting AWS instances: ${INSTANCE_IDS}"
                aws ec2 terminate-instances --region "${REGION}" --instance-ids ${INSTANCE_IDS} || echo "WARNING: AWS cleanup failed"
            else
                echo "No AWS instances found matching ${BYOH_INSTANCE_NAME}"
            fi
        else
            echo "WARNING: aws CLI not available, cannot cleanup AWS instances"
        fi
    elif [[ "${platform}" == "azure" ]]; then
        if command -v az &> /dev/null; then
            echo "Attempting Azure instance cleanup..."
            # Login using service principal credentials
            az login --service-principal -u "${ARM_CLIENT_ID}" -p "${ARM_CLIENT_SECRET}" --tenant "${ARM_TENANT_ID}" > /dev/null 2>&1 || echo "WARNING: Azure login failed"
            az account set --subscription "${ARM_SUBSCRIPTION_ID}" 2>/dev/null || echo "WARNING: Failed to set Azure subscription"

            # Get cluster infrastructure name to find resource group
            INFRA_ID=$(oc get infrastructure cluster -o=jsonpath="{.status.infrastructureName}" 2>/dev/null || echo "")
            if [[ -n "${INFRA_ID}" ]]; then
                RESOURCE_GROUP="${INFRA_ID}-rg"
                VMS=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[?contains(name, '${BYOH_INSTANCE_NAME}')].name" -o tsv 2>/dev/null || echo "")
                if [[ -n "${VMS}" ]]; then
                    echo "Deleting Azure VMs: ${VMS}"
                    echo "${VMS}" | xargs -r -I {} az vm delete --resource-group "${RESOURCE_GROUP}" --name {} --yes --no-wait || echo "WARNING: Azure VM cleanup failed"
                else
                    echo "No Azure VMs found matching ${BYOH_INSTANCE_NAME}"
                fi
            else
                echo "WARNING: Could not determine cluster infrastructure name"
            fi
        else
            echo "WARNING: az CLI not available, cannot cleanup Azure instances"
        fi
    else
        echo "Platform ${platform} - limited cleanup options available"
    fi
}

# Detect platform
PLATFORM=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.type}" | tr '[:upper:]' '[:lower:]' 2>/dev/null || echo "unknown")
echo "Platform detected: ${PLATFORM}"

# Verify byoh.sh is available
if ! command -v byoh.sh &> /dev/null; then
    echo "ERROR: byoh.sh not found in terraform-windows-provisioner image"
    cleanup_with_cloud_cli "${PLATFORM}"
    exit 0
fi

cd "${WORK_DIR}" || exit 1

# Verify Terraform state exists
TERRAFORM_STATE_FILE="${BYOH_TMP_DIR}${PLATFORM}/terraform.tfstate"
if [[ -f "${TERRAFORM_STATE_FILE}" ]]; then
    echo "✓ Terraform state found at ${TERRAFORM_STATE_FILE}"
else
    echo "WARNING: Terraform state not found at ${TERRAFORM_STATE_FILE}, will use cloud CLI fallback if needed"
fi

# Destroy Windows nodes using Terraform
# NOTE: Must pass same arguments as provision step to find correct terraform state directory
# Arguments: action, instance_name, num_workers, folder_suffix, windows_version
echo "Destroying Windows BYOH nodes via Terraform..."
if ! ./byoh.sh destroy "${BYOH_INSTANCE_NAME}" "${BYOH_NUM_WORKERS}" "" "${BYOH_WINDOWS_VERSION}"; then
    echo "WARNING: Terraform destroy failed, attempting cloud CLI cleanup as fallback..."
    cleanup_with_cloud_cli "${PLATFORM}"
fi

echo "✓ Windows BYOH cleanup completed"
