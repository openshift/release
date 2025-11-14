#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"

echo "💾 Creating IBM Storage Scale LocalDisk resources..."

# Get first worker node for LocalDisk creation
FIRST_WORKER=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | head -1 | awk '{print $1}')

# Create LocalDisk resources for EBS volumes (device names vary by instance type)
DEVICES=("nvme2n1" "nvme3n1")
DISK_COUNT=0

for device in "${DEVICES[@]}"; do
  LOCALDISK_NAME="shared-ebs-disk-${DISK_COUNT}"
  
  oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: LocalDisk
metadata:
  name: ${LOCALDISK_NAME}
  namespace: ${FA__SCALE__NAMESPACE}
spec:
  device: /dev/${device}
  node: ${FIRST_WORKER}
  nodeConnectionSelector:
    matchExpressions:
    - key: node-role.kubernetes.io/worker
      operator: Exists
  existingDataSkipVerify: true
EOF
  
  oc wait --for=jsonpath='{.metadata.name}'=${LOCALDISK_NAME} localdisk/${LOCALDISK_NAME} -n ${FA__SCALE__NAMESPACE} --timeout=300s
  echo "✅ LocalDisk ${LOCALDISK_NAME} created"
  
  ((DISK_COUNT++))
done

echo "✅ Created ${#DEVICES[@]} LocalDisk resources"
oc get localdisk -n ${FA__SCALE__NAMESPACE}

