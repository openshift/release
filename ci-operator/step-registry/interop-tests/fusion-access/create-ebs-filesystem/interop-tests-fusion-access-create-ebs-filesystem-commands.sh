#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

echo "🗂️  Creating IBM Storage Scale Filesystem for shared storage..."
echo "Note: Using manually specified EBS volumes"

# Check what disks are available (for debugging)
echo ""
echo "Checking available disks on worker nodes..."
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}' | head -3)
for node in $WORKER_NODES; do
  echo "Node: $node"
  oc debug node/$node -- chroot /host lsblk 2>/dev/null | grep -E "NAME|sd|nvme|xvd" | head -10 || echo "  Could not check disks"
done

# Reference LocalDisk resources that were created by create-local-disks step
# For shared storage, IBM Storage Scale requires LocalDisk resources
# instead of direct device paths. The LocalDisk resources represent the
# shared EBS volumes and manage multi-node access.
echo ""
echo "Creating Filesystem resource referencing LocalDisk resources..."
if oc apply -f=- <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Filesystem
metadata:
  name: shared-filesystem
  namespace: ${STORAGE_SCALE_NAMESPACE}
spec:
  local:
    blockSize: 4M
    pools:
    - name: system
      disks:
      - shared-ebs-disk-1
      - shared-ebs-disk-2
      - shared-ebs-disk-3
    replication: 1-way
    type: shared
  seLinuxOptions:
    level: s0
    role: object_r
    type: container_file_t
    user: system_u
EOF
then
  echo "✅ IBM Storage Scale Filesystem created successfully"
else
  echo "❌ Failed to create IBM Storage Scale Filesystem"
  echo "Checking for specific error details..."
  
  # Check if cluster exists
  if ! oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
    echo "❌ IBM Storage Scale Cluster not found"
    echo "Filesystem creation requires an existing cluster"
    echo "Please ensure the create-cluster step runs before this step"
  else
    echo "✅ Cluster exists, checking cluster status..."
    oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Success')].status"
  fi
  
  # Check for CRD availability
  if ! oc get crd filesystems.scale.spectrum.ibm.com >/dev/null 2>&1; then
    echo "❌ CRD filesystems.scale.spectrum.ibm.com not found"
    echo "This indicates the IBM Storage Scale operator is not properly installed"
  else
    echo "✅ Filesystem CRD is available"
  fi
  
  exit 1
fi

echo "Waiting for IBM Storage Scale Filesystem to be ready..."
echo "Note: Filesystem creation can take up to 1 hour for large configurations"

# Wait for Success condition to be True
if oc wait --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True filesystem/shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} --timeout=3600s; then
  echo "✅ IBM Storage Scale Filesystem is ready"
else
  echo "⚠️  IBM Storage Scale Filesystem not ready within 1 hour, checking status..."
  oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o yaml | grep -A 20 -B 5 "status:" || echo "No status information available"
  
  # Check for specific error conditions
  FILESYSTEM_SUCCESS=$(oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")
  FILESYSTEM_MESSAGE=$(oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Success")].message}' 2>/dev/null || echo "No message")
  echo "Current filesystem Success condition: $FILESYSTEM_SUCCESS"
  echo "Message: $FILESYSTEM_MESSAGE"
  
  # Check for events
  echo "Checking for filesystem-related events..."
  oc get events -n ${STORAGE_SCALE_NAMESPACE} --sort-by='.lastTimestamp' | grep -i filesystem | tail -10 || echo "No filesystem-related events found"
  
  # Show pod status
  echo ""
  echo "Checking IBM Storage Scale pod status..."
  oc get pods -n ${STORAGE_SCALE_NAMESPACE} 2>&1 | head -10 || echo "Cannot get pods"
fi

echo "Verifying IBM Storage Scale Filesystem..."
if oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} >/dev/null 2>&1; then
  echo "✅ IBM Storage Scale Filesystem found:"
  oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o custom-columns="NAME:.metadata.name,SUCCESS:.status.conditions[?(@.type=='Success')].status,STORAGECLASS:.status.storageClass"
else
  echo "❌ IBM Storage Scale Filesystem not found"
  echo "Checking for any Filesystem-related events..."
  oc get events -n ${STORAGE_SCALE_NAMESPACE} --sort-by='.lastTimestamp' | grep -i filesystem || echo "No Filesystem-related events found"
  exit 1
fi

echo "Checking for StorageClass created by IBM Storage Scale Filesystem..."
echo "Waiting for StorageClass to be available (up to 12 minutes)..."
STORAGECLASS_ATTEMPTS=0
MAX_STORAGECLASS_ATTEMPTS=24
while [[ $STORAGECLASS_ATTEMPTS -lt $MAX_STORAGECLASS_ATTEMPTS ]]; do
  if oc get storageclass | grep -i spectrum >/dev/null 2>&1; then
    echo "✅ IBM Storage Scale StorageClass found:"
    oc get storageclass | grep -i spectrum
    break
  else
    echo "⏳ Waiting for IBM Storage Scale StorageClass... (attempt $((STORAGECLASS_ATTEMPTS + 1))/$MAX_STORAGECLASS_ATTEMPTS)"
    sleep 30
    ((STORAGECLASS_ATTEMPTS++))
  fi
done

if [[ $STORAGECLASS_ATTEMPTS -eq $MAX_STORAGECLASS_ATTEMPTS ]]; then
  echo "⚠️  IBM Storage Scale StorageClass not found after 12 minutes"
  echo "Available StorageClasses:"
  oc get storageclass
  echo "This may indicate that the filesystem is not fully ready or there are issues with the storage configuration"
fi

echo "Filesystem deployment summary:"
echo "✅ IBM Storage Scale Filesystem: Created for multi-node access using EBS volumes"
echo ""
echo "Available storage options:"
echo "1. IBM Storage Scale local storage (for IBM Storage Scale operations)"
echo "2. IBM Storage Scale shared Filesystem (for application data sharing across pods)"
echo ""

echo "IBM Storage Scale Shared Storage Information:"
echo "EBS volumes: Using direct EBS volume access for shared storage"

echo ""
echo "Filesystem status:"
oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o custom-columns="NAME:.metadata.name,SUCCESS:.status.conditions[?(@.type=='Success')].status,STORAGECLASS:.status.storageClass" 2>/dev/null || echo "Filesystem not found"

echo ""
echo "Available StorageClasses for shared storage:"
oc get storageclass | grep -E "(spectrum|gp2)" || echo "No IBM Storage Scale or GP2 StorageClasses found"

echo "✅ IBM Storage Scale Filesystem creation completed!"
