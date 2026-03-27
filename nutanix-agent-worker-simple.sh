#!/bin/bash
#
# Simplified Nutanix Agent Worker Addition Script
# For manual operation scenarios - assumes you have already created VMs in Nutanix
#
# Usage:
#   1. Manually create VMs in Nutanix (powered off state)
#   2. Configure the environment variables below
#   3. Run this script
#

set -o nounset
set -o errexit
set -o pipefail

###########################################
# Configuration Section - Modify according to your environment
###########################################

# Nutanix connection information
NUTANIX_ENDPOINT="your-prism-central.example.com"
NUTANIX_USER="admin"
NUTANIX_PASSWORD="YourPassword"

# Nutanix VM UUID list (comma-separated)
# Obtain from Prism UI or API
NUTANIX_VM_UUIDS="vm-uuid-1,vm-uuid-2,vm-uuid-3"

# HyperShift cluster information
# If empty, will auto-detect the first HostedCluster
HOSTED_CLUSTER_NAME="${HOSTED_CLUSTER_NAME:-}"
HOSTED_CLUSTER_NAMESPACE="${HOSTED_CLUSTER_NAMESPACE:-}"

###########################################
# Main Process
###########################################

echo "========================================="
echo "Nutanix Agent Worker Addition Script"
echo "========================================="

# Auto-detect HostedCluster
if [[ -z "${HOSTED_CLUSTER_NAME}" ]]; then
    echo "Auto-detecting HostedCluster..."
    HOSTED_CLUSTER_NAMESPACE=$(oc get hostedcluster -A -o jsonpath='{.items[0].metadata.namespace}')
    HOSTED_CLUSTER_NAME=$(oc get hostedcluster -A -o jsonpath='{.items[0].metadata.name}')
fi

echo "HostedCluster: ${HOSTED_CLUSTER_NAME}"
echo "Namespace: ${HOSTED_CLUSTER_NAMESPACE}"

HOSTED_CONTROL_PLANE_NS="${HOSTED_CLUSTER_NAMESPACE}-${HOSTED_CLUSTER_NAME}"
echo "Control Plane Namespace: ${HOSTED_CONTROL_PLANE_NS}"

# Check SSH keys
if [[ ! -f ~/.ssh/id_rsa.pub ]]; then
    echo "Generating SSH key pair..."
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
fi
SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub)

###########################################
# Step 1: Create InfraEnv
###########################################
echo ""
echo "Step 1: Creating InfraEnv to generate Agent ISO..."

oc apply -f - <<EOF
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${HOSTED_CLUSTER_NAME}-nutanix
  namespace: ${HOSTED_CONTROL_PLANE_NS}
spec:
  cpuArchitecture: x86_64
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
EOF

echo "Waiting for ISO to be created (this may take a few minutes)..."
oc wait --timeout=10m \
    --for=condition=ImageCreated \
    -n ${HOSTED_CONTROL_PLANE_NS} \
    InfraEnv/${HOSTED_CLUSTER_NAME}-nutanix

###########################################
# Step 2: Download ISO
###########################################
echo ""
echo "Step 2: Downloading Agent ISO..."

ISO_URL=$(oc get InfraEnv/${HOSTED_CLUSTER_NAME}-nutanix \
    -n ${HOSTED_CONTROL_PLANE_NS} \
    -o jsonpath='{.status.isoDownloadURL}')

echo "ISO URL: ${ISO_URL}"

ISO_FILE="/tmp/nutanix-agent-$(date +%s).iso"
echo "Downloading to: ${ISO_FILE}"

curl -L --fail -o "${ISO_FILE}" --insecure "${ISO_URL}"
ISO_SIZE=$(du -h "${ISO_FILE}" | cut -f1)
echo "Downloaded: ${ISO_SIZE}"

###########################################
# Step 3: Upload ISO to Nutanix
###########################################
echo ""
echo "Step 3: Uploading ISO to Nutanix..."

ISO_NAME="agent-worker-$(date +%s).iso"
echo "Image name: ${ISO_NAME}"

# Create Image entity
IMAGE_CREATE_RESPONSE=$(curl -k -s -X POST \
    -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
    "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/images" \
    -H 'Content-Type: application/json' \
    -d "{
        \"spec\": {
            \"name\": \"${ISO_NAME}\",
            \"resources\": {
                \"image_type\": \"ISO_IMAGE\"
            }
        },
        \"metadata\": {
            \"kind\": \"image\",
            \"name\": \"${ISO_NAME}\"
        }
    }")

IMAGE_UUID=$(echo "${IMAGE_CREATE_RESPONSE}" | jq -r '.metadata.uuid')

if [[ "${IMAGE_UUID}" == "null" ]] || [[ -z "${IMAGE_UUID}" ]]; then
    echo "ERROR: Failed to create image in Nutanix"
    echo "Response: ${IMAGE_CREATE_RESPONSE}"
    exit 1
fi

echo "Image UUID: ${IMAGE_UUID}"

# Upload ISO file content
echo "Uploading ISO file content (this may take several minutes)..."
UPLOAD_RESPONSE=$(curl -k -s -w "\nHTTP_CODE:%{http_code}" -X PUT \
    -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
    "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/images/${IMAGE_UUID}/file" \
    -H "Content-Type: application/octet-stream" \
    --data-binary "@${ISO_FILE}")

HTTP_CODE=$(echo "${UPLOAD_RESPONSE}" | grep "HTTP_CODE:" | cut -d: -f2)

if [[ "${HTTP_CODE}" != "200" ]] && [[ "${HTTP_CODE}" != "201" ]]; then
    echo "ERROR: Failed to upload ISO (HTTP ${HTTP_CODE})"
    echo "${UPLOAD_RESPONSE}"
    exit 1
fi

echo "ISO uploaded successfully!"

###########################################
# Step 4: Mount ISO to VMs and power them on
###########################################
echo ""
echo "Step 4: Mounting ISO to VMs and powering them on..."

IFS=',' read -ra VM_UUID_ARRAY <<< "${NUTANIX_VM_UUIDS}"
NUM_VMS=${#VM_UUID_ARRAY[@]}

echo "Processing ${NUM_VMS} VMs..."

for vm_uuid in "${VM_UUID_ARRAY[@]}"; do
    vm_uuid=$(echo $vm_uuid | xargs)  # trim whitespace
    echo ""
    echo "Processing VM: ${vm_uuid}"

    # Get current VM configuration
    echo "  - Fetching current VM config..."
    VM_CONFIG=$(curl -k -s -X GET \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/${vm_uuid}")

    # Check if VM exists
    if echo "${VM_CONFIG}" | jq -e '.code' > /dev/null 2>&1; then
        echo "ERROR: VM ${vm_uuid} not found or inaccessible"
        echo "${VM_CONFIG}"
        continue
    fi

    VM_NAME=$(echo "${VM_CONFIG}" | jq -r '.spec.name')
    echo "  - VM Name: ${VM_NAME}"

    # Add CDROM device and set boot order
    echo "  - Adding CDROM device..."
    UPDATED_CONFIG=$(echo "${VM_CONFIG}" | jq \
        --arg img_uuid "${IMAGE_UUID}" \
        '
        # Add CDROM device
        .spec.resources.disk_list += [{
            "device_properties": {
                "device_type": "CDROM",
                "disk_address": {
                    "device_index": 0,
                    "adapter_type": "IDE"
                }
            },
            "data_source_reference": {
                "kind": "image",
                "uuid": $img_uuid
            }
        }] |
        # Set boot order: CDROM first, then DISK
        .spec.resources.boot_config.boot_device_order_list = ["CDROM", "DISK"] |
        # Clean up unnecessary fields
        del(.status)
        ')

    # Update VM configuration
    UPDATE_RESPONSE=$(curl -k -s -w "\nHTTP_CODE:%{http_code}" -X PUT \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/${vm_uuid}" \
        -H 'Content-Type: application/json' \
        -d "${UPDATED_CONFIG}")

    UPDATE_HTTP_CODE=$(echo "${UPDATE_RESPONSE}" | grep "HTTP_CODE:" | cut -d: -f2)

    if [[ "${UPDATE_HTTP_CODE}" != "200" ]] && [[ "${UPDATE_HTTP_CODE}" != "202" ]]; then
        echo "ERROR: Failed to update VM ${vm_uuid} (HTTP ${UPDATE_HTTP_CODE})"
        echo "${UPDATE_RESPONSE}"
        continue
    fi

    echo "  - VM updated with CDROM"

    # Wait for update to complete
    sleep 3

    # Power on VM
    echo "  - Powering on VM..."
    POWERON_RESPONSE=$(curl -k -s -w "\nHTTP_CODE:%{http_code}" -X POST \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/${vm_uuid}/acpi_power_on" \
        -H 'Content-Type: application/json')

    POWERON_HTTP_CODE=$(echo "${POWERON_RESPONSE}" | grep "HTTP_CODE:" | cut -d: -f2)

    if [[ "${POWERON_HTTP_CODE}" != "200" ]] && [[ "${POWERON_HTTP_CODE}" != "202" ]]; then
        echo "WARNING: Failed to power on VM ${vm_uuid} (HTTP ${POWERON_HTTP_CODE})"
        echo "${POWERON_RESPONSE}"
        echo "  You may need to power it on manually from Prism UI"
    else
        echo "  - VM powered on successfully"
    fi

    sleep 2
done

echo ""
echo "All VMs processed!"

###########################################
# Step 5: Wait for Agent registration
###########################################
echo ""
echo "Step 5: Waiting for Agent resources to register..."
echo "This may take 5-10 minutes as VMs boot from the ISO..."

WAIT_COUNT=0
MAX_WAIT=30  # 30 * 30 seconds = 15 minutes

while true; do
    AGENT_COUNT=$(oc get agent -n ${HOSTED_CONTROL_PLANE_NS} --no-headers --ignore-not-found 2>/dev/null | wc -l)
    echo "  Current agents: ${AGENT_COUNT}/${NUM_VMS} (attempt $((WAIT_COUNT+1))/${MAX_WAIT})"

    if [[ ${AGENT_COUNT} -ge ${NUM_VMS} ]]; then
        echo "All agents registered!"
        break
    fi

    WAIT_COUNT=$((WAIT_COUNT+1))
    if [[ ${WAIT_COUNT} -ge ${MAX_WAIT} ]]; then
        echo "WARNING: Timeout waiting for agents. Only ${AGENT_COUNT}/${NUM_VMS} registered."
        echo "You can continue manually or check VM console for issues."
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
        break
    fi

    sleep 30
done

###########################################
# Step 6: Approve Agents
###########################################
echo ""
echo "Step 6: Approving all agents..."

for agent in $(oc get agent -n ${HOSTED_CONTROL_PLANE_NS} --no-headers | awk '{print $1}'); do
    echo "  - Approving agent: ${agent}"
    oc patch agent -n ${HOSTED_CONTROL_PLANE_NS} ${agent} \
        -p '{"spec":{"approved":true}}' \
        --type merge
done

echo "All agents approved!"

###########################################
# Step 7: Scale NodePool
###########################################
echo ""
echo "Step 7: Scaling NodePool..."

# Get current NodePool
NODEPOOL_NAME=$(oc get nodepool -n ${HOSTED_CLUSTER_NAMESPACE} --no-headers | head -1 | awk '{print $1}')

if [[ -z "${NODEPOOL_NAME}" ]]; then
    echo "ERROR: No NodePool found for cluster ${HOSTED_CLUSTER_NAME}"
    exit 1
fi

echo "NodePool: ${NODEPOOL_NAME}"

# Get current replica count
CURRENT_REPLICAS=$(oc get nodepool ${NODEPOOL_NAME} -n ${HOSTED_CLUSTER_NAMESPACE} -o jsonpath='{.spec.replicas}')
NEW_REPLICAS=$((CURRENT_REPLICAS + NUM_VMS))

echo "Scaling from ${CURRENT_REPLICAS} to ${NEW_REPLICAS} replicas..."

oc scale nodepool ${NODEPOOL_NAME} \
    -n ${HOSTED_CLUSTER_NAMESPACE} \
    --replicas ${NEW_REPLICAS}

echo "NodePool scaled!"

###########################################
# Step 8: Wait for nodes to join
###########################################
echo ""
echo "Step 8: Waiting for nodes to join the cluster..."
echo "This may take 10-20 minutes as RHCOS is installed to the disks..."

oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NS} \
    --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster \
    --timeout=30m || {
        echo "WARNING: Some agents may not have joined in time"
        echo "Check agent status with:"
        echo "  oc get agent -n ${HOSTED_CONTROL_PLANE_NS}"
    }

###########################################
# Completion
###########################################
echo ""
echo "========================================="
echo "SUCCESS!"
echo "========================================="
echo ""
echo "Added ${NUM_VMS} Nutanix worker nodes to hosted cluster ${HOSTED_CLUSTER_NAME}"
echo ""
echo "Verify with:"
echo "  oc get agent -n ${HOSTED_CONTROL_PLANE_NS}"
echo "  oc get nodepool -n ${HOSTED_CLUSTER_NAMESPACE}"
echo "  oc get nodes --kubeconfig <hosted-cluster-kubeconfig>"
echo ""
echo "Cleanup:"
echo "  - ISO file: ${ISO_FILE}"
echo "  - Nutanix image: ${ISO_NAME} (UUID: ${IMAGE_UUID})"
echo ""
