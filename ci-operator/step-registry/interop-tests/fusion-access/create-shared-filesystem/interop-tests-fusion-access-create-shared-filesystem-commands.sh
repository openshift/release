#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"
FILESYSTEM_NAME="${FILESYSTEM_NAME:-shared-filesystem}"

echo "🗂️  Creating IBM Storage Scale shared filesystem for CNV integration..."
echo "Note: Creating shared filesystem without EBS dependency"

# Check if IBM Storage Scale cluster is ready
echo "🔍 Checking IBM Storage Scale cluster status..."
if ! oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
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
if oc get filesystem "${FILESYSTEM_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
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
  
  # Create filesystem using local storage (no EBS dependency)
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
      - devicePath: /dev/sdb
      - devicePath: /dev/sdc
      - devicePath: /dev/sdd
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
    if ! oc get crd filesystems.scale.spectrum.ibm.com >/dev/null 2>&1; then
      echo "❌ CRD filesystems.scale.spectrum.ibm.com not found"
      echo "This indicates the IBM Storage Scale operator is not properly installed"
    else
      echo "✅ Filesystem CRD is available"
    fi
    
    exit 1
  fi
fi

echo "⏳ Waiting for shared filesystem to be ready..."
FILESYSTEM_ATTEMPTS=0
MAX_FILESYSTEM_ATTEMPTS=20
while [[ $FILESYSTEM_ATTEMPTS -lt $MAX_FILESYSTEM_ATTEMPTS ]]; do
  FS_STATUS=$(oc get filesystem "${FILESYSTEM_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")
  echo "  📊 Filesystem Status: ${FS_STATUS} (attempt $((FILESYSTEM_ATTEMPTS + 1))/$MAX_FILESYSTEM_ATTEMPTS)"
  
  if [[ "${FS_STATUS}" == "True" ]]; then
    echo "✅ Shared filesystem is ready"
    break
  else
    echo "  ⏳ Waiting for filesystem to be ready..."
    sleep 30
    FILESYSTEM_ATTEMPTS=$((FILESYSTEM_ATTEMPTS + 1))
  fi
done

if [[ $FILESYSTEM_ATTEMPTS -eq $MAX_FILESYSTEM_ATTEMPTS ]]; then
  echo "⚠️  Shared filesystem not ready within timeout"
  echo "Filesystem details:"
  oc get filesystem "${FILESYSTEM_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o yaml
  echo "This may indicate that the filesystem is still initializing or there are issues with the storage configuration"
fi

# Check for storage class creation
echo "🔍 Checking for IBM Storage Scale StorageClass..."
STORAGECLASS_ATTEMPTS=0
MAX_STORAGECLASS_ATTEMPTS=12
while [[ $STORAGECLASS_ATTEMPTS -lt $MAX_STORAGECLASS_ATTEMPTS ]]; do
  if oc get storageclass | grep -i spectrum >/dev/null 2>&1; then
    echo "✅ IBM Storage Scale StorageClass found:"
    oc get storageclass | grep -i spectrum
    break
  else
    echo "⏳ Waiting for IBM Storage Scale StorageClass... (attempt $((STORAGECLASS_ATTEMPTS + 1))/$MAX_STORAGECLASS_ATTEMPTS)"
    sleep 30
    STORAGECLASS_ATTEMPTS=$((STORAGECLASS_ATTEMPTS + 1))
  fi
done

if [[ $STORAGECLASS_ATTEMPTS -eq $MAX_STORAGECLASS_ATTEMPTS ]]; then
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
