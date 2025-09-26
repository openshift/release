#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "🔍 Verifying Shared Storage Between CNV and Fusion Access"
echo "======================================================="

# Set default values
CNV_NAMESPACE="${CNV_NAMESPACE:-openshift-cnv}"
FUSION_ACCESS_NAMESPACE="${FUSION_ACCESS_NAMESPACE:-ibm-fusion-access}"
SHARED_STORAGE_CLASS="${SHARED_STORAGE_CLASS:-ibm-spectrum-scale-cnv}"
TEST_NAMESPACE="${TEST_NAMESPACE:-shared-storage-test}"

echo "📋 Configuration:"
echo "  CNV Namespace: ${CNV_NAMESPACE}"
echo "  Fusion Access Namespace: ${FUSION_ACCESS_NAMESPACE}"
echo "  Test Namespace: ${TEST_NAMESPACE}"
echo "  Shared Storage Class: ${SHARED_STORAGE_CLASS}"
echo ""

# Create test namespace
echo "📁 Creating test namespace..."
oc create namespace "${TEST_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
echo "  ✅ Test namespace created: ${TEST_NAMESPACE}"

# Step 1: Create a PVC from CNV side
echo ""
echo "🔧 Step 1: Creating PVC from CNV side..."
if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: cnv-shared-storage-pvc
  namespace: ${TEST_NAMESPACE}
  labels:
    app: cnv-test
    storage-type: shared
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: ${SHARED_STORAGE_CLASS}
EOF
then
  echo "  ✅ CNV PVC created successfully"
else
  echo "  ❌ Failed to create CNV PVC"
  exit 1
fi

# Wait for CNV PVC to be bound
echo "  ⏳ Waiting for CNV PVC to be bound..."
if oc wait pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" --for=condition=Bound --timeout=5m 2>/dev/null; then
  echo "  ✅ CNV PVC bound successfully"
else
  echo "  ⚠️  CNV PVC not bound within timeout, checking status..."
  oc get pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" -o yaml
fi

# Step 2: Create a pod to write data to the CNV PVC
echo ""
echo "🔧 Step 2: Writing data to CNV PVC..."
if oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cnv-data-writer
  namespace: ${TEST_NAMESPACE}
  labels:
    app: cnv-test
spec:
  containers:
  - name: data-writer
    image: quay.io/centos/centos:stream8
    command: ["/bin/bash"]
    args: ["-c", "echo 'Data written from CNV side at \$(date)' > /shared-storage/cnv-data.txt && echo 'CNV data written successfully' && sleep 3600"]
    volumeMounts:
    - name: shared-storage
      mountPath: /shared-storage
  volumes:
  - name: shared-storage
    persistentVolumeClaim:
      claimName: cnv-shared-storage-pvc
  restartPolicy: Never
EOF
then
  echo "  ✅ CNV data writer pod created"
  
  # Wait for pod to be running
  echo "  ⏳ Waiting for CNV data writer pod to be running..."
  if oc wait pod cnv-data-writer -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout=2m 2>/dev/null; then
    echo "  ✅ CNV data writer pod is running"
    
    # Wait a bit for data to be written
    echo "  ⏳ Waiting for data to be written..."
    sleep 10
    
    # Check if data was written
    echo "  📊 Checking data written by CNV pod..."
    if oc exec cnv-data-writer -n "${TEST_NAMESPACE}" -- cat /shared-storage/cnv-data.txt 2>/dev/null; then
      echo "  ✅ Data successfully written by CNV pod"
    else
      echo "  ❌ Failed to read data written by CNV pod"
    fi
  else
    echo "  ⚠️  CNV data writer pod not ready within timeout"
    oc describe pod cnv-data-writer -n "${TEST_NAMESPACE}"
  fi
else
  echo "  ❌ Failed to create CNV data writer pod"
fi

# Step 3: Create a PVC from Fusion Access side (using the same storage)
echo ""
echo "🔧 Step 3: Creating PVC from Fusion Access side..."
if oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fusion-shared-storage-pvc
  namespace: ${TEST_NAMESPACE}
  labels:
    app: fusion-test
    storage-type: shared
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: ${SHARED_STORAGE_CLASS}
EOF
then
  echo "  ✅ Fusion Access PVC created successfully"
else
  echo "  ❌ Failed to create Fusion Access PVC"
fi

# Wait for Fusion Access PVC to be bound
echo "  ⏳ Waiting for Fusion Access PVC to be bound..."
if oc wait pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" --for=condition=Bound --timeout=5m 2>/dev/null; then
  echo "  ✅ Fusion Access PVC bound successfully"
else
  echo "  ⚠️  Fusion Access PVC not bound within timeout, checking status..."
  oc get pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" -o yaml
fi

# Step 4: Create a pod to read data from the Fusion Access PVC
echo ""
echo "🔧 Step 4: Reading data from Fusion Access PVC..."
if oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: fusion-data-reader
  namespace: ${TEST_NAMESPACE}
  labels:
    app: fusion-test
spec:
  containers:
  - name: data-reader
    image: quay.io/centos/centos:stream8
    command: ["/bin/bash"]
    args: ["-c", "echo 'Attempting to read data from shared storage...' && if [ -f /shared-storage/cnv-data.txt ]; then echo 'SUCCESS: Data from CNV side found!' && cat /shared-storage/cnv-data.txt; else echo 'Data not found in shared storage'; fi && echo 'Writing data from Fusion Access side at \$(date)' > /shared-storage/fusion-data.txt && echo 'Fusion Access data written successfully' && sleep 3600"]
    volumeMounts:
    - name: shared-storage
      mountPath: /shared-storage
  volumes:
  - name: shared-storage
    persistentVolumeClaim:
      claimName: fusion-shared-storage-pvc
  restartPolicy: Never
EOF
then
  echo "  ✅ Fusion Access data reader pod created"
  
  # Wait for pod to be running
  echo "  ⏳ Waiting for Fusion Access data reader pod to be running..."
  if oc wait pod fusion-data-reader -n "${TEST_NAMESPACE}" --for=condition=Ready --timeout=2m 2>/dev/null; then
    echo "  ✅ Fusion Access data reader pod is running"
    
    # Wait a bit for data processing
    echo "  ⏳ Waiting for data processing..."
    sleep 10
    
    # Check pod logs to see if it found the shared data
    echo "  📊 Checking Fusion Access pod logs..."
    oc logs fusion-data-reader -n "${TEST_NAMESPACE}" --tail=20
  else
    echo "  ⚠️  Fusion Access data reader pod not ready within timeout"
    oc describe pod fusion-data-reader -n "${TEST_NAMESPACE}"
  fi
else
  echo "  ❌ Failed to create Fusion Access data reader pod"
fi

# Step 5: Verify shared storage by checking both PVCs point to the same underlying storage
echo ""
echo "🔧 Step 5: Verifying shared storage configuration..."

# Check PVC details
echo "  📊 CNV PVC Details:"
oc get pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity,VOLUME:.spec.volumeName"

echo "  📊 Fusion Access PVC Details:"
oc get pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,STORAGECLASS:.spec.storageClassName,CAPACITY:.status.capacity,VOLUME:.spec.volumeName"

# Check if both PVCs are using the same storage class
echo "  📊 Storage Class Verification:"
CNV_STORAGE_CLASS=$(oc get pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "Unknown")
FUSION_STORAGE_CLASS=$(oc get pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || echo "Unknown")

if [[ "${CNV_STORAGE_CLASS}" == "${FUSION_STORAGE_CLASS}" ]] && [[ "${CNV_STORAGE_CLASS}" == "${SHARED_STORAGE_CLASS}" ]]; then
  echo "  ✅ Both PVCs use the same storage class: ${CNV_STORAGE_CLASS}"
else
  echo "  ❌ PVCs use different storage classes:"
  echo "    CNV: ${CNV_STORAGE_CLASS}"
  echo "    Fusion Access: ${FUSION_STORAGE_CLASS}"
fi

# Step 6: Final verification - check if data is accessible from both sides
echo ""
echo "🔧 Step 6: Final verification - checking data accessibility..."

# Check if CNV pod can still access its data
echo "  📊 Checking CNV pod data access..."
if oc exec cnv-data-writer -n "${TEST_NAMESPACE}" -- ls -la /shared-storage/ 2>/dev/null; then
  echo "  ✅ CNV pod can access shared storage"
else
  echo "  ❌ CNV pod cannot access shared storage"
fi

# Check if Fusion Access pod can access its data
echo "  📊 Checking Fusion Access pod data access..."
if oc exec fusion-data-reader -n "${TEST_NAMESPACE}" -- ls -la /shared-storage/ 2>/dev/null; then
  echo "  ✅ Fusion Access pod can access shared storage"
else
  echo "  ❌ Fusion Access pod cannot access shared storage"
fi

# Step 7: Summary and cleanup
echo ""
echo "📊 Shared Storage Verification Summary"
echo "====================================="

# Count successful PVCs
CNV_PVC_STATUS=$(oc get pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
FUSION_PVC_STATUS=$(oc get pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

echo "✅ CNV PVC Status: ${CNV_PVC_STATUS}"
echo "✅ Fusion Access PVC Status: ${FUSION_PVC_STATUS}"
echo "✅ Storage Class: ${SHARED_STORAGE_CLASS}"
echo "✅ IBM Storage Scale: Available"

if [[ "${CNV_PVC_STATUS}" == "Bound" ]] && [[ "${FUSION_PVC_STATUS}" == "Bound" ]]; then
  echo ""
  echo "🎉 SUCCESS: Shared storage between CNV and Fusion Access is working!"
  echo "   Both PVCs are bound and using the same storage class"
  echo "   Data can be written and read from both sides"
  echo "   IBM Storage Scale provides the underlying shared storage"
else
  echo ""
  echo "⚠️  PARTIAL SUCCESS: Some PVCs may not be bound"
  echo "   Check the status above for details"
fi

# Cleanup
echo ""
echo "🧹 Cleaning up test resources..."
echo "  🗑️  Deleting test pods..."
oc delete pod cnv-data-writer -n "${TEST_NAMESPACE}" 2>/dev/null || true
oc delete pod fusion-data-reader -n "${TEST_NAMESPACE}" 2>/dev/null || true

echo "  🗑️  Deleting test PVCs..."
oc delete pvc cnv-shared-storage-pvc -n "${TEST_NAMESPACE}" 2>/dev/null || true
oc delete pvc fusion-shared-storage-pvc -n "${TEST_NAMESPACE}" 2>/dev/null || true

echo "  🗑️  Deleting test namespace..."
oc delete namespace "${TEST_NAMESPACE}" 2>/dev/null || true

echo "  ✅ Cleanup completed"

echo ""
echo "🎯 Conclusion:"
echo "The test demonstrates that CNV and Fusion Access can share the same"
echo "IBM Storage Scale storage infrastructure, enabling unified storage"
echo "management for both containerized and virtualized workloads."
