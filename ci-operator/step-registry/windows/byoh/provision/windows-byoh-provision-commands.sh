#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "=== Windows BYOH Provisioning with terraform-windows-provisioner ==="

# Set defaults
export BYOH_INSTANCE_NAME="${BYOH_INSTANCE_NAME:-byoh-winc}"
export BYOH_NUM_WORKERS="${BYOH_NUM_WORKERS:-2}"
export BYOH_WINDOWS_VERSION="${BYOH_WINDOWS_VERSION:-2022}"
export BYOH_TMP_DIR="/tmp/terraform_byoh/"

# Windows credentials (optional - byoh.sh will auto-generate if not provided)
# WINC_ADMIN_PASSWORD can be set via secret, otherwise byoh.sh generates a random password
# WINC_SSH_PUBLIC_KEY will be auto-extracted from cloud-private-key secret by byoh.sh
echo "Note: byoh.sh will auto-extract SSH key from cloud-private-key secret and auto-generate password if needed"

# Export credentials from cluster profile (platform-agnostic)
# terraform-windows-provisioner will auto-detect platform and use appropriate credentials
if [[ -f "${CLUSTER_PROFILE_DIR}/.awscred" ]]; then
    export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    export AWS_PROFILE="default"
    echo "✓ AWS credentials configured"
fi

if [[ -f "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json" ]]; then
    ARM_CLIENT_ID=$(jq -r .clientId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    ARM_CLIENT_SECRET=$(jq -r .clientSecret "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    ARM_SUBSCRIPTION_ID=$(jq -r .subscriptionId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    ARM_TENANT_ID=$(jq -r .tenantId "${CLUSTER_PROFILE_DIR}/osServicePrincipal.json")
    export ARM_CLIENT_ID ARM_CLIENT_SECRET ARM_SUBSCRIPTION_ID ARM_TENANT_ID
    echo "✓ Azure credentials configured"
fi

if [[ -f "${CLUSTER_PROFILE_DIR}/gce.json" ]]; then
    GOOGLE_CREDENTIALS=$(cat "${CLUSTER_PROFILE_DIR}/gce.json")
    export GOOGLE_CREDENTIALS
    echo "✓ GCP credentials configured"
fi

# Install terraform
echo "Installing Terraform..."
TERRAFORM_VERSION="1.0.11"
curl -L -o /tmp/terraform.gz https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip \
    && gunzip /tmp/terraform.gz \
    && chmod +x /tmp/terraform
export PATH=/tmp:${PATH}
terraform version -no-color
echo "✓ Terraform installed"

# Clone terraform-windows-provisioner
# TODO: Change to official repo after PR is merged:
#       git clone https://github.com/openshift/terraform-windows-provisioner.git /tmp/terraform-windows-provisioner
git clone -b terraform-scripts https://github.com/rrasouli/terraform-windows-provisioner-1.git /tmp/terraform-windows-provisioner
cd /tmp/terraform-windows-provisioner

echo "Provisioning ${BYOH_NUM_WORKERS} Windows ${BYOH_WINDOWS_VERSION} nodes..."
./byoh.sh apply "${BYOH_INSTANCE_NAME}" "${BYOH_NUM_WORKERS}" "" "${BYOH_WINDOWS_VERSION}"

# Wait for BYOH nodes specifically to be Ready (identified by WMCO label)
READY_TIMEOUT="${BYOH_READY_TIMEOUT:-45m}"
echo "Waiting for ${BYOH_NUM_WORKERS} BYOH Windows nodes to become Ready (timeout: ${READY_TIMEOUT})..."
timeout "${READY_TIMEOUT}" bash -c '
    while true; do
        READY=$(oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true --no-headers 2>/dev/null | grep "Ready" | wc -l)
        echo "BYOH nodes ready: ${READY}/'${BYOH_NUM_WORKERS}'"
        if [[ "${READY}" -ge "'${BYOH_NUM_WORKERS}'" ]]; then
            break
        fi
        sleep 30
    done
'

echo "✓ Windows BYOH nodes provisioned successfully"
echo "All Windows nodes in cluster:"
oc get nodes -l kubernetes.io/os=windows -o wide
echo ""
echo "BYOH nodes specifically (labeled windowsmachineconfig.openshift.io/byoh=true):"
oc get nodes -l kubernetes.io/os=windows,windowsmachineconfig.openshift.io/byoh=true -o wide

# Export instance information for WMCO BYOH e2e tests
echo "Exporting Windows instance information to SHARED_DIR for WMCO tests..."

# Detect platform
PLATFORM=$(oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.type}" | tr '[:upper:]' '[:lower:]')

# Get instance IPs from Terraform output
TERRAFORM_DIR="${BYOH_TMP_DIR}${PLATFORM}"
if [[ ! -d "${TERRAFORM_DIR}" ]]; then
    echo "ERROR: Terraform directory not found: ${TERRAFORM_DIR}"
    exit 1
fi

cd /tmp/terraform-windows-provisioner
INSTANCE_IPS=$(terraform -chdir="${TERRAFORM_DIR}" output -json instance_ip 2>/dev/null | jq -r '.[]' || echo "")

if [[ -z "${INSTANCE_IPS}" ]]; then
    echo "WARNING: No instance IPs found in Terraform output"
    # Fallback: get from node IPs
    INSTANCE_IPS=$(oc get nodes -l kubernetes.io/os=windows -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
fi

# Determine username based on platform
case "${PLATFORM}" in
    azure)
        USERNAME="capi"
        ;;
    *)
        USERNAME="Administrator"
        ;;
esac

# Write instance files in WMCO BYOH format
# Format: ${SHARED_DIR}/<ip>_windows_instance.txt containing "username: <username>"
for ip in ${INSTANCE_IPS}; do
    instance_file="${SHARED_DIR}/${ip}_windows_instance.txt"
    cat > "${instance_file}" <<EOF
username: ${USERNAME}
EOF
    echo "✓ Created instance file: ${instance_file}"
done

echo "✓ Instance information exported for WMCO BYOH tests"

# Save work dir and Terraform state for cleanup
echo "/tmp/terraform-windows-provisioner" > "${SHARED_DIR}/byoh_work_dir"

# Copy Terraform state to SHARED_DIR so destroy step can access it
if [[ -f "${TERRAFORM_DIR}/terraform.tfstate" ]]; then
    echo "Saving Terraform state to SHARED_DIR..."
    cp "${TERRAFORM_DIR}/terraform.tfstate" "${SHARED_DIR}/terraform.tfstate"
    echo "✓ Terraform state saved"
else
    echo "WARNING: Terraform state file not found at ${TERRAFORM_DIR}/terraform.tfstate"
fi

echo "=== Windows BYOH Provisioning Complete ==="
