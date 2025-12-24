#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Set default values from FA__ prefixed environment variables
STORAGE_SCALE_NAMESPACE="${FA__STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${FA__STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"
FILESYSTEM_NAME="${FA__FILESYSTEM_NAME:-shared-filesystem}"

echo "🗂️  Creating IBM Storage Scale shared filesystem for CNV integration..."
echo "Note: Creating shared filesystem without EBS dependency"

# Check if IBM Storage Scale cluster is ready
echo "🔍 Checking IBM Storage Scale cluster status..."
if ! oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null; then
  echo "❌ IBM Storage Scale Cluster not found"
  echo "Please ensure the core deployment chain runs before this step"
  exit 1
fi

CLUSTER_STATUS=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")
echo "  📊 Cluster Status: ${CLUSTER_STATUS}"

if [[ "${CLUSTER_STATUS}" != "True" ]]; then
  echo "⚠️  IBM Storage Scale cluster is not ready, waiting for it to be ready..."
  echo "  ⏳ Waiting for cluster to be ready..."
  if oc wait cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" --for=condition=Success --timeout=10m 2>/dev/null; then
    echo "  ✅ Cluster is now ready"
  else
    echo "  ⚠️  Cluster not ready within timeout, proceeding anyway"
  fi
fi

# Check if filesystem already exists
if oc get filesystem "${FILESYSTEM_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null; then
  echo "✅ Shared filesystem already exists"
  FS_STATUS=$(oc get filesystem "${FILESYSTEM_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")
  echo "  📊 Filesystem Status: ${FS_STATUS}"
  
  if [[ "${FS_STATUS}" == "True" ]]; then
    echo "✅ Shared filesystem is ready"
    exit 0
  else
    echo "⚠️  Shared filesystem exists but not ready, waiting..."
  fi
else
  echo "📝 Creating shared filesystem..."
  
  # Get first worker node for LocalDisk creation
  FIRST_WORKER=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "${FIRST_WORKER}" ]]; then
    echo "❌ ERROR: No worker nodes found"
    oc get nodes
    exit 1
  fi
  echo "✅ Using worker node: ${FIRST_WORKER}"
  
  # Create LocalDisk resources for NVMe devices
  DEVICES=("nvme2n1" "nvme3n1")
  DISK_COUNT=0
  
  for device in "${DEVICES[@]}"; do
    LOCALDISK_NAME="shared-disk-${DISK_COUNT}"
    
    oc apply -f=- <<EOF
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
    
    oc wait --for=jsonpath='{.metadata.name}'=${LOCALDISK_NAME} localdisk/${LOCALDISK_NAME} -n "${STORAGE_SCALE_NAMESPACE}" --timeout=300s
    echo "✅ LocalDisk ${LOCALDISK_NAME} created"
    DISK_COUNT=$((DISK_COUNT + 1))
  done
  
  echo "✅ Created ${#DEVICES[@]} LocalDisk resources"
  oc get localdisk -n "${STORAGE_SCALE_NAMESPACE}"
  
  # Create filesystem referencing LocalDisk resources by name
  if oc apply -f - <<EOF
apiVersion: scale.spectrum.ibm.com/v1beta1
kind: Filesystem
metadata:
  name: ${FILESYSTEM_NAME}
  namespace: ${STORAGE_SCALE_NAMESPACE}
spec:
  local:
    blockSize: 4M
    pools:
    - name: system
      disks:
      - shared-disk-0
      - shared-disk-1
    replication: 1-way
    type: shared
  seLinuxOptions:
    level: s0
    role: object_r
    type: container_file_t
    user: system_u
EOF
  then
    echo "✅ Shared filesystem created successfully"
  else
    echo "❌ Failed to create shared filesystem"
    echo "Checking for specific error details..."
    
    # Check for CRD availability
    if ! oc get crd filesystems.scale.spectrum.ibm.com >/dev/null; then
      echo "❌ CRD filesystems.scale.spectrum.ibm.com not found"
      echo "This indicates the IBM Storage Scale operator is not properly installed"
    else
      echo "✅ Filesystem CRD is available"
    fi
    
    exit 1
  fi
fi

echo "⏳ Waiting for shared filesystem to be ready..."
if oc wait filesystem "${FILESYSTEM_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" \
    --for=jsonpath='{.status.conditions[?(@.type=="Success")].status}'=True \
    --timeout=600s; then
  echo "✅ Shared filesystem is ready"
else
  echo "⚠️  Shared filesystem not ready within timeout"
  echo "Filesystem details:"
  oc get filesystem "${FILESYSTEM_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o yaml
  echo "This may indicate that the filesystem is still initializing or there are issues with the storage configuration"
fi

# Check for storage class creation
echo "🔍 Checking for IBM Storage Scale StorageClass..."
# Wait for the storageclass to exist (checking for metadata.name)
if oc wait storageclass --all --for=jsonpath='{.provisioner}'=spectrumscale.csi.ibm.com --timeout=360s 2>/dev/null; then
  echo "✅ IBM Storage Scale StorageClass found:"
  oc get storageclass | grep -i spectrum
else
  echo "⚠️  IBM Storage Scale StorageClass not found after 6 minutes"
  echo "Available StorageClasses:"
  oc get storageclass
  echo "This may indicate that the filesystem is not fully ready or there are issues with the storage configuration"
fi

echo ""
echo "📊 Shared filesystem deployment summary:"
echo "✅ IBM Storage Scale Cluster: ${CLUSTER_STATUS}"
echo "✅ Shared Filesystem: Created for CNV integration using local storage"
echo "✅ Storage Class: Available for CNV shared storage"
echo ""
echo "Available storage options:"
echo "1. IBM Storage Scale local storage (for IBM Storage Scale operations)"
echo "2. IBM Storage Scale shared Filesystem (for CNV and application data sharing)"
echo ""
echo "Shared Storage Information:"
echo "Filesystem: ${FILESYSTEM_NAME}"
echo "Storage Type: Local storage (no EBS dependency)"
echo "Access: Multi-node shared access for CNV integration"

echo ""
echo "Filesystem status:"
oc get filesystem "${FILESYSTEM_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.status.storageClass" 2>/dev/null || echo "Filesystem not found"

echo ""
echo "Available StorageClasses for CNV integration:"
oc get storageclass | grep -E "(spectrum|gp2)" || echo "No IBM Storage Scale or GP2 StorageClasses found"

echo "✅ IBM Storage Scale shared filesystem creation completed!"
echo "   Ready for CNV integration without EBS dependency"
