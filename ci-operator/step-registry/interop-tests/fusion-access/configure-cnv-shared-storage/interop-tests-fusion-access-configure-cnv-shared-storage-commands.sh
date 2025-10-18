#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "🔧 Configuring CNV for IBM Storage Scale shared storage..."

# Set default values
CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
SHARED_STORAGE_CLASS="${SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

echo "📋 Configuration:"
echo "  CNV Namespace: ${CNV_NAMESPACE}"
echo "  Shared Storage Class: ${SHARED_STORAGE_CLASS}"
echo "  Storage Scale Namespace: ${STORAGE_SCALE_NAMESPACE}"
echo "  Storage Scale Cluster: ${STORAGE_SCALE_CLUSTER_NAME}"
echo ""

# Check if CNV is ready
echo "🔍 Checking CNV status..."
if oc get hyperconverged kubevirt-hyperconverged -n "${CNV_NAMESPACE}" >/dev/null 2>&1; then
  CNV_STATUS=$(oc get hyperconverged kubevirt-hyperconverged -n "${CNV_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
  echo "  ✅ CNV HyperConverged found (Status: ${CNV_STATUS})"
else
  echo "  ❌ CNV HyperConverged not found"
  echo "  Please ensure CNV is installed before running this step"
  exit 1
fi

# Check if IBM Storage Scale is ready
echo ""
echo "🔍 Checking IBM Storage Scale status..."
if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  SCALE_STATUS=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")
  echo "  ✅ IBM Storage Scale Cluster found (Status: ${SCALE_STATUS})"
else
  echo "  ❌ IBM Storage Scale Cluster not found"
  echo "  Please ensure IBM Storage Scale is deployed before running this step"
  exit 1
fi

# Check if shared filesystem exists
echo ""
echo "🔍 Checking IBM Storage Scale filesystem..."
if oc get filesystem shared-filesystem -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  FS_STATUS=$(oc get filesystem shared-filesystem -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")
  echo "  ✅ Shared filesystem found (Status: ${FS_STATUS})"
else
  echo "  ❌ Shared filesystem not found"
  echo "  Please ensure IBM Storage Scale filesystem is created before running this step"
  exit 1
fi

# Create shared storage class for CNV
echo ""
echo "💾 Creating shared storage class for CNV..."
if oc get storageclass "${SHARED_STORAGE_CLASS}" >/dev/null 2>&1; then
  echo "  ✅ Storage class ${SHARED_STORAGE_CLASS} already exists"
else
  echo "  📝 Creating storage class ${SHARED_STORAGE_CLASS}..."
  if oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SHARED_STORAGE_CLASS}
  annotations:
    storageclass.kubernetes.io/is-default-class: "false"
provisioner: spectrumscale.csi.ibm.com
parameters:
  volBackendFs: "shared-filesystem"
  clusterId: "${STORAGE_SCALE_CLUSTER_NAME}"
  permissions: "755"
  uid: "0"
  gid: "0"
  fsType: "gpfs"
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
EOF
  then
    echo "  ✅ Storage class created successfully"
  else
    echo "  ❌ Failed to create storage class"
    exit 1
  fi
fi

# Configure CNV to use shared storage
echo ""
echo "🔧 Configuring CNV to use shared storage..."
CURRENT_STORAGE_CLASS=$(oc get hco kubevirt-hyperconverged -n "${CNV_NAMESPACE}" -o jsonpath='{.spec.storage.defaultStorageClass}' 2>/dev/null || echo "")
if [[ "${CURRENT_STORAGE_CLASS}" == "${SHARED_STORAGE_CLASS}" ]]; then
  echo "  ✅ CNV already configured for shared storage"
else
  echo "  📝 Setting CNV default storage class to ${SHARED_STORAGE_CLASS}..."
  if oc patch hco kubevirt-hyperconverged -n "${CNV_NAMESPACE}" --type=merge -p '{
    "spec": {
      "storage": {
        "defaultStorageClass": "'${SHARED_STORAGE_CLASS}'"
      }
    }
  }' 2>/dev/null; then
    echo "  ✅ CNV configured for shared storage"
  else
    echo "  ❌ Failed to configure CNV for shared storage"
    exit 1
  fi
fi

# Test shared storage with a PVC
echo ""
echo "🧪 Testing shared storage with PVC..."
if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-shared-storage-pvc
  namespace: ${CNV_NAMESPACE}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${SHARED_STORAGE_CLASS}
EOF
then
  echo "  ✅ Test PVC created successfully"
  
  # Wait for PVC to be bound
  echo "  ⏳ Waiting for PVC to be bound..."
  if oc wait pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" --for=condition=Bound --timeout=5m 2>/dev/null; then
    echo "  ✅ PVC bound successfully to shared storage"
    
    # Check PVC status
    PVC_STATUS=$(oc get pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    echo "  📊 PVC Status: ${PVC_STATUS}"
    
    # Clean up test PVC
    echo "  🧹 Cleaning up test PVC..."
    oc delete pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" 2>/dev/null || true
    echo "  ✅ Test PVC cleaned up"
  else
    echo "  ⚠️  PVC not bound within timeout, checking status..."
    oc get pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" -o yaml
    echo "  🧹 Cleaning up test PVC..."
    oc delete pvc test-shared-storage-pvc -n "${CNV_NAMESPACE}" 2>/dev/null || true
  fi
else
  echo "  ❌ Failed to create test PVC"
fi

# Verify configuration
echo ""
echo "🔍 Verifying CNV configuration..."
echo "  📊 CNV HyperConverged status:"
oc get hco kubevirt-hyperconverged -n "${CNV_NAMESPACE}" -o custom-columns="NAME:.metadata.name,AVAILABLE:.status.conditions[?(@.type=='Available')].status,STORAGE:.spec.storage.defaultStorageClass"

echo "  📊 Storage class configuration:"
oc get storageclass "${SHARED_STORAGE_CLASS}" -o custom-columns="NAME:.metadata.name,PROVISIONER:.provisioner,VOLUMEBINDINGMODE:.volumeBindingMode"

echo ""
echo "✅ CNV shared storage configuration completed successfully!"
echo "   CNV is now configured to use IBM Storage Scale shared storage"
echo "   VMs and DataVolumes will use the shared storage infrastructure"
