#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ add-worker nutanix command ************"

# Source Nutanix context from IPI workflow
if [[ -f "${SHARED_DIR}/nutanix_context.sh" ]]; then
    echo "Loading Nutanix context from IPI workflow..."
    source "${SHARED_DIR}/nutanix_context.sh"

    # Map IPI workflow variables to our naming convention
    NUTANIX_ENDPOINT="${NUTANIX_HOST}"
    NUTANIX_USER="${NUTANIX_USERNAME}"
    # NUTANIX_PASSWORD is already set from nutanix_context.sh
    NUTANIX_CLUSTER_NAME="${PE_NAME//\"/}"  # Remove quotes

    echo "Using Nutanix endpoint: ${NUTANIX_ENDPOINT}"
    echo "Using Nutanix cluster: ${NUTANIX_CLUSTER_NAME}"
else
    echo "WARNING: nutanix_context.sh not found, using environment variables directly"
    NUTANIX_ENDPOINT="${NUTANIX_ENDPOINT}"
    NUTANIX_USER="${NUTANIX_USER}"
    NUTANIX_PASSWORD="${NUTANIX_PASSWORD}"
    NUTANIX_CLUSTER_NAME="${NUTANIX_CLUSTER}"
fi

NUM_EXTRA_WORKERS="${NUM_EXTRA_WORKERS:-1}"

# Get HostedCluster information
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}')
HOSTED_CLUSTER_NAME=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.name}')
HOSTED_CONTROL_PLANE_NAMESPACE="${HOSTED_CLUSTER_NS}-${HOSTED_CLUSTER_NAME}"

echo "Creating InfraEnv for Nutanix workers"
SSH_PUB_KEY=$(cat ~/.ssh/id_rsa.pub)

# Create InfraEnv to generate Agent ISO
oc apply -f - <<EOF
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${HOSTED_CLUSTER_NAME}
  namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}
spec:
  cpuArchitecture: x86_64
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: ${SSH_PUB_KEY}
EOF

echo "Waiting for ISO to be created..."
oc wait --timeout=10m --for=condition=ImageCreated \
  -n ${HOSTED_CONTROL_PLANE_NAMESPACE} \
  InfraEnv/${HOSTED_CLUSTER_NAME}

# Get ISO download URL
ISO_DOWNLOAD_URL=$(oc get InfraEnv/${HOSTED_CLUSTER_NAME} \
  -n ${HOSTED_CONTROL_PLANE_NAMESPACE} \
  -ojsonpath='{.status.isoDownloadURL}')

echo "ISO Download URL: ${ISO_DOWNLOAD_URL}"

# Download ISO locally
ISO_FILE="${SHARED_DIR}/agent-worker.iso"
curl -L --fail -o "${ISO_FILE}" --insecure "${ISO_DOWNLOAD_URL}"
echo "ISO downloaded to ${ISO_FILE}"

# Key step: Upload ISO to Nutanix and mount to VMs
echo "Uploading ISO to Nutanix and mounting to VMs..."

# Use Nutanix CLI (ncli) or REST API
# Examples of both methods provided below

# Method 1: Use Nutanix REST API (recommended)
# Requires jq and curl
upload_iso_to_nutanix() {
    local iso_file=$1
    local iso_name="agent-worker-$(date +%s).iso"

    # Upload ISO to Nutanix Image Service
    # Note: Adjust API endpoint based on your Nutanix version
    echo "Uploading ISO as ${iso_name}..."

    # Create Image
    local image_uuid=$(curl -k -X POST \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/images" \
        -H 'Content-Type: application/json' \
        -d "{
            \"spec\": {
                \"name\": \"${iso_name}\",
                \"resources\": {
                    \"image_type\": \"ISO_IMAGE\"
                }
            },
            \"metadata\": {
                \"kind\": \"image\",
                \"name\": \"${iso_name}\"
            }
        }" | jq -r '.metadata.uuid')

    echo "Created image with UUID: ${image_uuid}"

    # Upload ISO file content
    curl -k -X PUT \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/images/${image_uuid}/file" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${iso_file}"

    echo "ISO uploaded successfully"
    echo "${image_uuid}"
}

# Method 2: Use prism_central CLI (if you have CLI access)
# This requires SSH access to Nutanix CVM or nCLI installation

# Upload ISO
IMAGE_UUID=$(upload_iso_to_nutanix "${ISO_FILE}")

# Mount ISO to existing VMs and power them on
echo "Mounting ISO to VMs and powering them on..."

# Get list of VMs to use
# Option 1: Read pre-defined VM UUID list from environment variable
if [[ -n "${NUTANIX_WORKER_VM_UUIDS:-}" ]]; then
    IFS=',' read -ra VM_UUIDS <<< "${NUTANIX_WORKER_VM_UUIDS}"
else
    # Option 2: Find VMs by label or name pattern
    # Assuming VMs have specific label "hypershift-worker=true"
    VM_UUIDS=($(curl -k -X POST \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/list" \
        -H 'Content-Type: application/json' \
        -d '{
            "kind": "vm",
            "filter": "name==hypershift-worker.*"
        }' | jq -r '.entities[].metadata.uuid' | head -n ${NUM_EXTRA_WORKERS}))
fi

# Mount ISO and start each VM
for vm_uuid in "${VM_UUIDS[@]}"; do
    echo "Processing VM: ${vm_uuid}"

    # Get current VM configuration
    vm_config=$(curl -k -X GET \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/${vm_uuid}")

    # Extract necessary information and add CDROM
    spec_version=$(echo "${vm_config}" | jq -r '.metadata.spec_version')

    # Update VM configuration: add CDROM device
    curl -k -X PUT \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/${vm_uuid}" \
        -H 'Content-Type: application/json' \
        -d "$(echo "${vm_config}" | jq --arg img_uuid "${IMAGE_UUID}" '
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
            .spec.resources.boot_config.boot_device_order_list = ["CDROM", "DISK"]
        ')"

    # Power on VM
    echo "Powering on VM ${vm_uuid}..."
    curl -k -X POST \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/${vm_uuid}/power_on" \
        -H 'Content-Type: application/json'

    sleep 5
done

echo "All VMs powered on with Agent ISO"

# Wait for Agent resources to be created
echo "Waiting for Agent resources to be created..."
_agentExist=0
set +e
for ((i=1; i<=20; i++)); do
    count=$(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --no-headers --ignore-not-found | wc -l)
    if [ ${count} -eq ${NUM_EXTRA_WORKERS} ]; then
        echo "All ${NUM_EXTRA_WORKERS} agent resources exist"
        _agentExist=1
        break
    fi
    echo "Waiting on agent resources (${count}/${NUM_EXTRA_WORKERS})... attempt ${i}/20"
    sleep 30
done
set -e

if [ $_agentExist -eq 0 ]; then
    echo "FATAL: Expected ${NUM_EXTRA_WORKERS} agents, found ${count}"
    exit 1
fi

# Approve all Agents
echo "Approving all agents..."
for item in $(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --no-headers | awk '{print $1}'); do
    oc patch agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} ${item} \
        -p '{"spec":{"approved":true}}' --type merge
    echo "Approved agent: ${item}"
done

# Scale NodePool
echo "Scaling nodepool to ${NUM_EXTRA_WORKERS} replicas..."
oc scale nodepool ${HOSTED_CLUSTER_NAME} \
    -n ${HOSTED_CLUSTER_NS} \
    --replicas ${NUM_EXTRA_WORKERS}

# Wait for all Agents to join the cluster
echo "Waiting for agents to join the cluster..."
oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} \
    --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster \
    --timeout=30m

echo "Successfully added ${NUM_EXTRA_WORKERS} Nutanix worker nodes to the hosted cluster!"
