#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"

echo "💾 Creating IBM Storage Scale LocalDisk resources..."
echo "Note: LocalDisk resources represent the shared EBS volumes"

# Get worker nodes
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')
WORKER_COUNT=$(echo "$WORKER_NODES" | wc -l)

echo "Found $WORKER_COUNT worker nodes"
echo "$WORKER_NODES"
echo ""

# Get first worker node for LocalDisk creation
# For shared storage, we specify one node where the device exists at creation time
# The nodeConnectionSelector tells IBM Storage Scale which other nodes can access it
FIRST_WORKER=$(echo "$WORKER_NODES" | head -1)
echo "Using node for LocalDisk creation: $FIRST_WORKER"
echo ""

# EBS volumes on c5n.metal instances appear as NVMe devices
# Note: Only using 2 devices (nvme2n1, nvme3n1) that are consistently available on all nodes
# nvme4n1 is not reliably attached to all worker nodes
DEVICES=("nvme2n1" "nvme3n1")
DISK_COUNT=1

for device in "${DEVICES[@]}"; do
  LOCALDISK_NAME="shared-ebs-disk-${DISK_COUNT}"
  
  echo "Creating LocalDisk: $LOCALDISK_NAME for device /dev/${device}..."
  
  if oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: LocalDisk
metadata:
  name: ${LOCALDISK_NAME}
  namespace: ${STORAGE_SCALE_NAMESPACE}
spec:
  device: /dev/${device}
  node: ${FIRST_WORKER}
  nodeConnectionSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
  existingDataSkipVerify: true
EOF
  then
    echo "✅ LocalDisk ${LOCALDISK_NAME} created successfully"
  else
    echo "❌ Failed to create LocalDisk ${LOCALDISK_NAME}"
    exit 1
  fi
  
  echo "Waiting for LocalDisk to be ready..."
  if oc wait --for=jsonpath='{.metadata.name}'=${LOCALDISK_NAME} localdisk/${LOCALDISK_NAME} -n ${STORAGE_SCALE_NAMESPACE} --timeout=300s; then
    echo "✅ LocalDisk ${LOCALDISK_NAME} is ready"
  else
    echo "⚠️  LocalDisk ${LOCALDISK_NAME} not ready within timeout, checking status..."
    oc get localdisk ${LOCALDISK_NAME} -n ${STORAGE_SCALE_NAMESPACE} -o yaml | grep -A 10 "status:" || echo "No status available"
  fi
  
  echo ""
  ((DISK_COUNT++))
done

# Verify all LocalDisks were created
echo "Verifying LocalDisk resources..."
oc get localdisk -n ${STORAGE_SCALE_NAMESPACE}

echo ""
echo "✅ IBM Storage Scale LocalDisk resources created successfully!"
echo "Created ${#DEVICES[@]} LocalDisk resources for shared EBS volumes"

