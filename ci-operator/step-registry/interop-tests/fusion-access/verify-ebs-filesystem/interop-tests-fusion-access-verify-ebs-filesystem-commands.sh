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
  
  # Check if status is empty or unknown
  if [[ -z "$FILESYSTEM_STATUS" ]] || [[ "$FILESYSTEM_STATUS" == "Unknown" ]]; then
    echo "⚠️  IBM Storage Scale Filesystem status is not set"
    FILESYSTEM_STATUS="<none>"
  fi
  
  if [[ -z "$FILESYSTEM_STORAGECLASS" ]] || [[ "$FILESYSTEM_STORAGECLASS" == "Unknown" ]]; then
    echo "⚠️  IBM Storage Scale Filesystem StorageClass is not set"
    FILESYSTEM_STORAGECLASS="<none>"
  fi
  
  echo "IBM Storage Scale Filesystem status: $FILESYSTEM_STATUS"
  echo "StorageClass: $FILESYSTEM_STORAGECLASS"
  
  # Get filesystem details
  echo "Filesystem details:"
  oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o custom-columns="NAME:.metadata.name,NAMESPACE:.metadata.namespace,STATUS:.status.phase,STORAGECLASS:.status.storageClass,AGE:.metadata.creationTimestamp"
  
  # Check for filesystem conditions
  echo "Filesystem conditions:"
  # Use jsonpath to get conditions directly without jq dependency
  oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o jsonpath='{range .status.conditions[*]}  {.type}: {.status} - {.message}{"\n"}{end}' 2>/dev/null || echo "  No conditions available"
  
else
  echo "❌ IBM Storage Scale Filesystem not found"
  echo "Checking for filesystem-related events..."
  oc get events -n ${STORAGE_SCALE_NAMESPACE} --sort-by='.lastTimestamp' | grep -i filesystem | tail -5 || echo "No filesystem-related events found"
  
  echo "Checking for available filesystems in namespace..."
  oc get filesystem -n ${STORAGE_SCALE_NAMESPACE} || echo "No filesystems found in namespace"
  
  echo "❌ IBM Storage Scale Filesystem verification failed!"
  exit 1
fi

# Check for StorageClass created by IBM Storage Scale
echo ""
echo "Checking for IBM Storage Scale StorageClass..."
if oc get storageclass | grep -i spectrum >/dev/null 2>&1; then
  echo "✅ IBM Storage Scale StorageClass found:"
  oc get storageclass -o custom-columns="NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIMPOLICY:.reclaimPolicy,VOLUMEBINDINGMODE:.volumeBindingMode" | grep -i spectrum
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
STORAGE_EVENTS=$(oc get events -n ${STORAGE_SCALE_NAMESPACE} --sort-by='.lastTimestamp' | grep -E "(Warning|Error)" | tail -10 || echo "")
if [[ -n "$STORAGE_EVENTS" ]]; then
  echo "⚠️  Found warning/error events:"
  echo "$STORAGE_EVENTS"
else
  echo "No warning/error events found"
fi

# Final verification
echo ""
echo "🔍 Final verification..."

# Check if filesystem resource exists but is not properly configured
if oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} >/dev/null 2>&1; then
  FILESYSTEM_STATUS=$(oc get filesystem shared-filesystem -n ${STORAGE_SCALE_NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  
  # Check for critical issues
  CRITICAL_ISSUES=false
  
  if [[ -z "$FILESYSTEM_STATUS" ]]; then
    echo "❌ Filesystem status is not set - filesystem may not be properly configured"
    CRITICAL_ISSUES=true
  fi
  
  # Check for failed mount events
  FAILED_MOUNTS=$(oc get events -n ${STORAGE_SCALE_NAMESPACE} --sort-by='.lastTimestamp' | grep -c "FailedMount" || echo "0")
  if [[ $FAILED_MOUNTS -gt 0 ]]; then
    echo "⚠️  Found $FAILED_MOUNTS FailedMount events - volumes may not be mounting correctly"
    CRITICAL_ISSUES=true
  fi
  
  # Check if StorageClass exists
  if ! oc get storageclass | grep -i spectrum >/dev/null 2>&1; then
    echo "⚠️  No IBM Storage Scale StorageClass found - filesystem may not be fully operational"
  fi
  
  if [[ "$CRITICAL_ISSUES" == "true" ]]; then
    echo ""
    echo "❌ IBM Storage Scale Filesystem verification failed - critical issues detected!"
    exit 1
  else
    echo ""
    echo "✅ IBM Storage Scale Filesystem verification completed!"
  fi
else
  echo "❌ IBM Storage Scale Filesystem not found!"
  exit 1
fi
