#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ hypershift nutanix conf workers command ************"

# This step creates Nutanix VMs for HyperShift hosted cluster workers
# It can be used instead of pre-creating VMs manually

NUTANIX_ENDPOINT="${NUTANIX_ENDPOINT}"
NUTANIX_USER="${NUTANIX_USER:-admin}"
NUTANIX_PASSWORD="${NUTANIX_PASSWORD}"
NUTANIX_CLUSTER="${NUTANIX_CLUSTER}"
NUTANIX_SUBNET_UUID="${NUTANIX_SUBNET_UUID}"

NUM_WORKERS="${NUM_EXTRA_WORKERS:-3}"
WORKER_VCPU="${NUTANIX_WORKER_VCPU:-8}"
WORKER_MEMORY_MB="${NUTANIX_WORKER_MEMORY:-16384}"
WORKER_DISK_GB="${NUTANIX_WORKER_DISK:-120}"
WORKER_NAME_PREFIX="${NUTANIX_WORKER_VM_PREFIX:-hypershift-worker}"

echo "Creating ${NUM_WORKERS} Nutanix worker VMs..."
echo "Configuration: ${WORKER_VCPU} vCPU, ${WORKER_MEMORY_MB} MB RAM, ${WORKER_DISK_GB} GB disk"

# Get Nutanix cluster UUID
CLUSTER_UUID=$(curl -k -s -X POST \
    -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
    "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/clusters/list" \
    -H 'Content-Type: application/json' \
    -d "{\"kind\":\"cluster\",\"filter\":\"name==${NUTANIX_CLUSTER}\"}" \
    | jq -r '.entities[0].metadata.uuid')

if [[ -z "${CLUSTER_UUID}" ]] || [[ "${CLUSTER_UUID}" == "null" ]]; then
    echo "ERROR: Could not find Nutanix cluster: ${NUTANIX_CLUSTER}"
    exit 1
fi

echo "Nutanix cluster UUID: ${CLUSTER_UUID}"

# Create VMs
VM_UUIDS=()

for ((i=0; i<NUM_WORKERS; i++)); do
    VM_NAME="${WORKER_NAME_PREFIX}-${i}"
    echo ""
    echo "Creating VM: ${VM_NAME}"

    # Create VM spec
    VM_SPEC=$(cat <<EOF
{
  "spec": {
    "name": "${VM_NAME}",
    "resources": {
      "power_state": "OFF",
      "num_vcpus_per_socket": ${WORKER_VCPU},
      "num_sockets": 1,
      "memory_size_mib": ${WORKER_MEMORY_MB},
      "disk_list": [
        {
          "device_properties": {
            "device_type": "DISK",
            "disk_address": {
              "device_index": 0,
              "adapter_type": "SCSI"
            }
          },
          "disk_size_mib": $((WORKER_DISK_GB * 1024))
        }
      ],
      "nic_list": [
        {
          "subnet_reference": {
            "kind": "subnet",
            "uuid": "${NUTANIX_SUBNET_UUID}"
          }
        }
      ],
      "boot_config": {
        "boot_device_order_list": ["CDROM", "DISK"]
      }
    },
    "cluster_reference": {
      "kind": "cluster",
      "uuid": "${CLUSTER_UUID}"
    }
  },
  "metadata": {
    "kind": "vm",
    "name": "${VM_NAME}"
  }
}
EOF
)

    # Create the VM
    CREATE_RESPONSE=$(curl -k -s -w "\nHTTP_CODE:%{http_code}" -X POST \
        -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
        "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms" \
        -H 'Content-Type: application/json' \
        -d "${VM_SPEC}")

    HTTP_CODE=$(echo "${CREATE_RESPONSE}" | grep "HTTP_CODE:" | cut -d: -f2)
    RESPONSE_BODY=$(echo "${CREATE_RESPONSE}" | sed '/HTTP_CODE:/d')

    if [[ "${HTTP_CODE}" != "200" ]] && [[ "${HTTP_CODE}" != "202" ]]; then
        echo "ERROR: Failed to create VM ${VM_NAME} (HTTP ${HTTP_CODE})"
        echo "${RESPONSE_BODY}"
        exit 1
    fi

    VM_UUID=$(echo "${RESPONSE_BODY}" | jq -r '.metadata.uuid')

    if [[ -z "${VM_UUID}" ]] || [[ "${VM_UUID}" == "null" ]]; then
        echo "ERROR: Failed to get UUID for VM ${VM_NAME}"
        echo "${RESPONSE_BODY}"
        exit 1
    fi

    echo "Created VM ${VM_NAME} with UUID: ${VM_UUID}"
    VM_UUIDS+=("${VM_UUID}")

    # Wait for VM to be ready
    echo "Waiting for VM to be ready..."
    for attempt in {1..30}; do
        VM_STATE=$(curl -k -s -X GET \
            -u "${NUTANIX_USER}:${NUTANIX_PASSWORD}" \
            "https://${NUTANIX_ENDPOINT}:9440/api/nutanix/v3/vms/${VM_UUID}" \
            | jq -r '.status.state')

        if [[ "${VM_STATE}" == "COMPLETE" ]]; then
            echo "VM is ready"
            break
        fi

        if [[ $attempt -eq 30 ]]; then
            echo "WARNING: VM did not reach COMPLETE state in time (current: ${VM_STATE})"
        fi

        sleep 5
    done

    sleep 2
done

# Save VM UUIDs for subsequent steps
VM_UUIDS_STR=$(IFS=,; echo "${VM_UUIDS[*]}")
echo "${VM_UUIDS_STR}" > "${SHARED_DIR}/nutanix-worker-vm-uuids"
echo "export NUTANIX_WORKER_VM_UUIDS='${VM_UUIDS_STR}'" >> "${SHARED_DIR}/nutanix-worker-config"

echo ""
echo "Successfully created ${NUM_WORKERS} Nutanix worker VMs"
echo "VM UUIDs: ${VM_UUIDS_STR}"
echo "Configuration saved to ${SHARED_DIR}/nutanix-worker-config"
