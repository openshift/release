#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"

echo "🔍 Verifying IBM Storage Scale Filesystem status..."

# Check filesystem status
if oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} >/dev/null 2>&1; then
  echo "✅ IBM Storage Scale Filesystem found"
  
  # Get detailed filesystem status
  FILESYSTEM_STATUS=$(oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  FILESYSTEM_STORAGECLASS=$(oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o jsonpath='{.status.storageClass}' 2>/dev/null || echo "Unknown")
  
  echo "IBM Storage Scale Filesystem: ✅ $FILESYSTEM_STATUS"
  echo "StorageClass: $FILESYSTEM_STORAGECLASS"
  
  # Get filesystem details
  echo "Filesystem details:"
  oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o custom-columns="NAME:.metadata.name,NAMESPACE:.metadata.namespace,STATUS:.status.phase,STORAGECLASS:.status.storageClass,AGE:.metadata.creationTimestamp"
  
  # Check for filesystem conditions
  echo "Filesystem conditions:"
  oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o jsonpath='{.status.conditions[*]}' | jq -r '.[] | "\(.type): \(.status) - \(.message)"' 2>/dev/null || echo "No conditions available or could not parse"
  
else
  echo "❌ IBM Storage Scale Filesystem not found"
  echo "Checking for filesystem-related events..."
  oc get events -n ${STORAGE_SCALE_NAMESPACE} --sort-by='.lastTimestamp' | grep -i filesystem | tail -5 || echo "No filesystem-related events found"
  
  echo "Checking for available filesystems in namespace..."
  oc get filesystem -n ${STORAGE_SCALE_NAMESPACE} || echo "No filesystems found in namespace"
fi

# Check for StorageClass created by IBM Storage Scale
echo ""
echo "Checking for IBM Storage Scale StorageClass..."
if oc get storageclass | grep -i spectrum >/dev/null 2>&1; then
  echo "✅ IBM Storage Scale StorageClass found:"
  oc get storageclass | grep -i spectrum -o custom-columns="NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIMPOLICY:.reclaimPolicy,VOLUMEBINDINGMODE:.volumeBindingMode"
else
  echo "⚠️  No IBM Storage Scale StorageClass found"
  echo "Available StorageClasses:"
  oc get storageclass -o custom-columns="NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIMPOLICY:.reclaimPolicy"
fi

# Check for persistent volumes
echo ""
echo "Checking for persistent volumes..."
PV_COUNT=$(oc get pv --no-headers 2>/dev/null | wc -l)
if [[ $PV_COUNT -gt 0 ]]; then
  echo "✅ Found $PV_COUNT persistent volumes:"
  oc get pv -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name,STORAGECLASS:.spec.storageClassName,AGE:.metadata.creationTimestamp"
else
  echo "⚠️  No persistent volumes found"
fi

# Check for persistent volume claims
echo ""
echo "Checking for persistent volume claims in IBM Storage Scale namespace..."
PVC_COUNT=$(oc get pvc -n ${STORAGE_SCALE_NAMESPACE} --no-headers 2>/dev/null | wc -l)
if [[ $PVC_COUNT -gt 0 ]]; then
  echo "✅ Found $PVC_COUNT persistent volume claims:"
  oc get pvc -n ${STORAGE_SCALE_NAMESPACE} -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,VOLUME:.spec.volumeName,STORAGECLASS:.spec.storageClassName,AGE:.metadata.creationTimestamp"
else
  echo "⚠️  No persistent volume claims found in namespace"
fi

# Check for any storage-related events
echo ""
echo "Checking for storage-related events..."
oc get events -n ${STORAGE_SCALE_NAMESPACE} --sort-by='.lastTimestamp' | grep -E "(storage|volume|pvc|pv)" | tail -5 || echo "No storage-related events found"

echo "✅ IBM Storage Scale Filesystem verification completed!"
