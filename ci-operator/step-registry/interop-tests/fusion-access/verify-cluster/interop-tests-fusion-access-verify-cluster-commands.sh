#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

echo "🔍 Verifying IBM Storage Scale Cluster status..."

# Wait for pods to be created and start scheduling
echo "⏳ Waiting for IBM Storage Scale pods to be created..."
MAX_WAIT_TIME=300  # 5 minutes
WAIT_TIME=0
POD_COUNT=0

while [[ $WAIT_TIME -lt $MAX_WAIT_TIME ]]; do
  POD_COUNT=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
  if [[ $POD_COUNT -gt 0 ]]; then
    echo "✅ Found $POD_COUNT IBM Storage Scale pods after ${WAIT_TIME}s"
    break
  fi
  echo "⏳ Waiting for pods to be created... (${WAIT_TIME}s/${MAX_WAIT_TIME}s)"
  sleep 10
  WAIT_TIME=$((WAIT_TIME + 10))
done

if [[ $POD_COUNT -eq 0 ]]; then
  echo "⚠️  No IBM Storage Scale pods found after ${MAX_WAIT_TIME}s"
  echo "This may indicate that the cluster deployment failed or is taking longer than expected"
fi

# Check cluster status
if oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
  echo "✅ IBM Storage Scale Cluster found"
  
  # Get detailed cluster status
  CLUSTER_STATUS=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].status}' 2>/dev/null || echo "Unknown")
  CLUSTER_MESSAGE=$(oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Success")].message}' 2>/dev/null || echo "No message available")
  
  if [[ "$CLUSTER_STATUS" == "True" ]]; then
    echo "IBM Storage Scale Cluster: ✅ Ready"
    echo "Status message: $CLUSTER_MESSAGE"
  else
    echo "IBM Storage Scale Cluster: ⚠️  Not ready (Status: $CLUSTER_STATUS)"
    echo "Status message: $CLUSTER_MESSAGE"
    
    # Check for quorum-related issues
    if [[ "$CLUSTER_MESSAGE" == *"quorum"* ]] || [[ "$CLUSTER_MESSAGE" == *"Quorum"* ]]; then
      echo "❌ Quorum-related issue detected"
      echo "This is likely due to insufficient worker nodes for quorum"
      
      # Count worker nodes
      WORKER_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l)
      echo "Current worker node count: $WORKER_NODE_COUNT"
      echo "IBM Storage Scale requires at least 3 worker nodes for quorum"
    fi
    
    # Get all cluster conditions for debugging
    echo "All cluster conditions:"
    oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[*]}' | jq -r '.[] | "\(.type): \(.status) - \(.message)"' 2>/dev/null || echo "Could not parse cluster conditions"
  fi
  
  # Get cluster details
  echo "Cluster details:"
  oc get cluster "${STORAGE_SCALE_CLUSTER_NAME}" -n "${STORAGE_SCALE_NAMESPACE}" -o custom-columns="NAME:.metadata.name,NAMESPACE:.metadata.namespace,AGE:.metadata.creationTimestamp"
  
else
  echo "❌ IBM Storage Scale Cluster not found"
  echo "Checking for cluster-related events..."
  oc get events -n "${STORAGE_SCALE_NAMESPACE}" --sort-by='.lastTimestamp' | grep -i cluster | tail -5 || echo "No cluster-related events found"
  
  echo "Checking for available clusters in namespace..."
  oc get cluster -n "${STORAGE_SCALE_NAMESPACE}" || echo "No clusters found in namespace"
fi

# Check for IBM Storage Scale pods
echo ""
echo "Checking IBM Storage Scale pods..."
POD_COUNT=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
if [[ $POD_COUNT -gt 0 ]]; then
  echo "✅ Found $POD_COUNT IBM Storage Scale pods:"
  oc get pods -n "${STORAGE_SCALE_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,AGE:.metadata.creationTimestamp"
  
  # Check pod readiness with better pattern matching
  READY_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Running" {print $1}' | wc -l)
  PENDING_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Pending" {print $1}' | wc -l)
  FAILED_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Failed" {print $1}' | wc -l)
  IMAGE_PULL_BACKOFF=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "ImagePullBackOff" {print $1}' | wc -l)
  CONTAINER_CREATING=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "ContainerCreating" {print $1}' | wc -l)
  INIT_IMAGE_PULL_BACKOFF=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Init:ImagePullBackOff" {print $1}' | wc -l)
  OTHER_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 != "Running" && $3 != "Pending" && $3 != "Failed" && $3 != "ImagePullBackOff" && $3 != "ContainerCreating" && $3 != "Init:ImagePullBackOff" {print $1}' | wc -l)
  
  echo "Running pods: $READY_PODS/$POD_COUNT"
  echo "Pending pods: $PENDING_PODS/$POD_COUNT"
  echo "Failed pods: $FAILED_PODS/$POD_COUNT"
  echo "ImagePullBackOff pods: $IMAGE_PULL_BACKOFF/$POD_COUNT"
  echo "ContainerCreating pods: $CONTAINER_CREATING/$POD_COUNT"
  echo "Init:ImagePullBackOff pods: $INIT_IMAGE_PULL_BACKOFF/$POD_COUNT"
  echo "Other status pods: $OTHER_PODS/$POD_COUNT"
  
  # Debug: Show actual pod statuses
  echo "Debug - Pod status breakdown:"
  oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '{print "  " $1 ": " $3}' | sort
  
  # Check for image pull issues first (most common cause)
  if [[ $IMAGE_PULL_BACKOFF -gt 0 ]] || [[ $INIT_IMAGE_PULL_BACKOFF -gt 0 ]] || [[ $CONTAINER_CREATING -gt 0 ]]; then
    echo "⚠️  Found image pull issues. Investigating..."
    
    # Check each pod with image pull issues
    for pod in $(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "ImagePullBackOff" || $3 == "Init:ImagePullBackOff" || $3 == "ContainerCreating" {print $1}'); do
      echo ""
      echo "🔍 Investigating image pull issues for pod: $pod"
      
      # Get pod events related to image pull
      echo "📅 Pod events for $pod:"
      oc get events -n "${STORAGE_SCALE_NAMESPACE}" --field-selector involvedObject.name="$pod" --sort-by='.lastTimestamp' | grep -i "pull\|image\|backoff" || echo "No image pull events found"
      
      # Get pod description for image pull errors
      echo "📊 Pod description for $pod:"
      oc describe pod "$pod" -n "${STORAGE_SCALE_NAMESPACE}" | grep -A 10 -B 5 -i "pull\|image\|backoff\|error" || echo "No image pull errors found in description"
      
      # Check container status
      echo "🐳 Container status for $pod:"
      oc get pod "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.containerStatuses[*].state}' 2>/dev/null || echo "Could not get container status"
    done
    
    # Check for pull secrets
    echo ""
    echo "🔐 Checking for pull secrets in ${STORAGE_SCALE_NAMESPACE} namespace:"
    PULL_SECRETS=$(oc get secrets -n "${STORAGE_SCALE_NAMESPACE}" --no-headers 2>/dev/null | grep -i pull || echo "")
    if [[ -n "$PULL_SECRETS" ]]; then
      echo "Pull secrets found:"
      echo "$PULL_SECRETS"
    else
      echo "No pull secrets found in namespace"
    fi
    
    # Check for image pull secrets in default service account
    echo ""
    echo "🔑 Checking default service account for image pull secrets:"
    SA_SECRETS=$(oc get serviceaccount default -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || echo "")
    if [[ -n "$SA_SECRETS" ]]; then
      echo "Service account pull secrets: $SA_SECRETS"
    else
      echo "⚠️  No image pull secrets in default service account"
    fi
    
    # Check for IBM entitlement credentials
    echo ""
    echo "🏢 Checking for IBM entitlement credentials:"
    if oc get secret ibm-entitlement-key -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
      echo "✅ ibm-entitlement-key found"
    else
      echo "❌ ibm-entitlement-key not found - this is likely the cause of image pull failures"
      echo "   The IBM Storage Scale images require IBM entitlement credentials to pull from icr.io"
    fi
    
    # Check for additional pull secrets that might be needed
    echo ""
    echo "🔍 Checking for additional pull secrets:"
    for secret in "fusion-pullsecret" "fusion-pullsecret-extra"; do
      if oc get secret "$secret" -n "${STORAGE_SCALE_NAMESPACE}" >/dev/null 2>&1; then
        echo "✅ $secret found"
      else
        echo "ℹ️  $secret not found (may not be required in this namespace)"
      fi
    done
  fi
  
  # If there are pending pods, investigate why
  if [[ $PENDING_PODS -gt 0 ]]; then
    echo "⚠️  Found $PENDING_PODS pending pods. Investigating..."
    
    # Get detailed pod information first
    echo "📋 Detailed pod information:"
    oc get pods -n "${STORAGE_SCALE_NAMESPACE}" -o wide
    
    # Check each pending pod for scheduling issues
    for pod in $(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | grep "Pending" | awk '{print $1}'); do
      echo ""
      echo "🔍 Investigating pending pod: $pod"
      
      # Get pod events (more comprehensive)
      echo "📅 Pod events for $pod:"
      oc get events -n "${STORAGE_SCALE_NAMESPACE}" --field-selector involvedObject.name="$pod" --sort-by='.lastTimestamp' || echo "No events found for $pod"
      
      # Get pod status conditions
      echo "📊 Pod status conditions for $pod:"
      oc get pod "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[*]}' | jq -r '.[] | "\(.type): \(.status) - \(.message)"' 2>/dev/null || echo "Could not get pod conditions"
      
      # Get scheduling condition specifically
      echo "🎯 Scheduling condition for $pod:"
      oc get pod "$pod" -n "${STORAGE_SCALE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")]}' 2>/dev/null || echo "No scheduling condition found"
    done
    
    echo ""
    echo "🔍 Cluster-level diagnostics:"
    
    # Check node resources
    echo "📊 Node information:"
    echo "Total nodes: $(oc get nodes --no-headers | wc -l)"
    echo "Worker nodes: $(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)"
    echo "Control plane nodes: $(oc get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)"
    
    # Check node capacity
    echo "💾 Node capacity:"
    oc get nodes -o custom-columns="NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory" || echo "Could not get node capacity"
    
    # Check for taints that might prevent scheduling
    echo "🚫 Node taints:"
    oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints[*].key}{"\n"}{end}' | grep -v "^$" || echo "No taints found"
    
    # Check resource quotas
    echo "📈 Resource quotas in namespace:"
    oc get resourcequota -n "${STORAGE_SCALE_NAMESPACE}" || echo "No resource quotas found"
    
    # Check for storage class issues
    echo "💾 Storage classes:"
    oc get storageclass || echo "No storage classes found"
    
    # Check for persistent volumes
    echo "💿 Persistent volumes:"
    oc get pv || echo "No persistent volumes found"
    
    # Check for persistent volume claims
    echo "📦 Persistent volume claims in namespace:"
    oc get pvc -n "${STORAGE_SCALE_NAMESPACE}" || echo "No PVCs found in namespace"
    
    # Check namespace events
    echo "📅 Namespace events:"
    oc get events -n "${STORAGE_SCALE_NAMESPACE}" --sort-by='.lastTimestamp' | tail -10 || echo "No events found in namespace"
    
    # Quick diagnostic summary
    echo ""
    echo "🔍 Quick diagnostic summary:"
    echo "1. Check if nodes have sufficient resources:"
    oc get nodes -o custom-columns="NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory" | head -5
    
    echo ""
    echo "2. Check for any resource constraints in pod descriptions:"
    for pod in $(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | grep "Pending" | awk '{print $1}' | head -2); do
      echo "Pod $pod scheduling issues:"
      oc describe pod "$pod" -n "${STORAGE_SCALE_NAMESPACE}" | grep -A 5 -B 5 "Warning\|Error" || echo "No warnings/errors found"
    done
    
    echo ""
    echo "3. Check if storage is available:"
    oc get storageclass | grep -v "NAME" | head -3 || echo "No storage classes available"
  fi
  
  # Check for any failed pods (including Init failures)
  FAILED_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | grep -E "(Failed|Error|CrashLoopBackOff|Init:CrashLoopBackOff|Init:Error)" | wc -l)
  if [[ $FAILED_PODS -gt 0 ]]; then
    echo "⚠️  Found $FAILED_PODS failed pods:"
    oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | grep -E "(Failed|Error|CrashLoopBackOff|Init:CrashLoopBackOff|Init:Error)"
  fi
else
  echo "⚠️  No IBM Storage Scale pods found"
  echo "This may indicate that the cluster is not properly deployed or the operator is not running"
fi

# Check for daemon resources
echo ""
echo "Checking IBM Storage Scale daemon resources..."
DAEMON_COUNT=$(oc get daemon -n "${STORAGE_SCALE_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
if [[ $DAEMON_COUNT -gt 0 ]]; then
  echo "✅ Found $DAEMON_COUNT IBM Storage Scale daemon resources:"
  oc get daemon -n "${STORAGE_SCALE_NAMESPACE}" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,AGE:.metadata.creationTimestamp"
else
  echo "⚠️  No IBM Storage Scale daemon resources found"
fi

# Final verification - check if pods are actually ready
echo ""
echo "🔍 Final verification - checking pod readiness..."
READY_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Running" {print $1}' | wc -l)
PENDING_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Pending" {print $1}' | wc -l)
IMAGE_PULL_BACKOFF=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "ImagePullBackOff" {print $1}' | wc -l)
INIT_IMAGE_PULL_BACKOFF=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Init:ImagePullBackOff" {print $1}' | wc -l)
CONTAINER_CREATING=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "ContainerCreating" {print $1}' | wc -l)
# Only count healthy Init pods (Init:0/2, Init:1/2), exclude failed Init states
INIT_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 ~ /^Init:[0-9]/ {print $1}' | wc -l)
FAILED_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Failed" {print $1}' | wc -l)
CRASHLOOP_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "CrashLoopBackOff" {print $1}' | wc -l)
INIT_CRASHLOOP_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Init:CrashLoopBackOff" {print $1}' | wc -l)
INIT_ERROR_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | awk '$3 == "Init:Error" {print $1}' | wc -l)
TOTAL_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | wc -l)

# Calculate acceptable pods (Running + healthy Init pods only)
ACCEPTABLE_PODS=$((READY_PODS + INIT_PODS))
PROBLEMATIC_PODS=$((PENDING_PODS + IMAGE_PULL_BACKOFF + INIT_IMAGE_PULL_BACKOFF + FAILED_PODS + CRASHLOOP_PODS + INIT_CRASHLOOP_PODS + INIT_ERROR_PODS))

echo "📊 Pod status summary:"
echo "- Total pods: $TOTAL_PODS"
echo "- Running pods: $READY_PODS"
echo "- Init pods (initializing): $INIT_PODS"
echo "- Acceptable pods (Running + Init): $ACCEPTABLE_PODS"
echo "- Problematic pods: $PROBLEMATIC_PODS"

if [[ $TOTAL_PODS -gt 0 ]]; then
  # Check if all pods are in acceptable states (Running or Init)
  if [[ $PROBLEMATIC_PODS -eq 0 ]]; then
    echo "✅ All IBM Storage Scale pods are in acceptable states ($ACCEPTABLE_PODS/$TOTAL_PODS)"
    echo "✅ IBM Storage Scale Cluster verification completed successfully!"
  else
    echo "⚠️  Some IBM Storage Scale pods are in problematic states ($PROBLEMATIC_PODS/$TOTAL_PODS)"
    echo "❌ IBM Storage Scale Cluster verification failed - pods are not ready"
    
    # Provide summary of issues
    echo ""
    echo "📋 Summary of issues found:"
    echo "- Total pods: $TOTAL_PODS"
    echo "- Running pods: $READY_PODS"
    echo "- Init pods (initializing): $INIT_PODS"
    echo "- Acceptable pods (Running + Init): $ACCEPTABLE_PODS"
    echo "- Pending pods: $PENDING_PODS"
    echo "- ImagePullBackOff pods: $IMAGE_PULL_BACKOFF"
    echo "- Init:ImagePullBackOff pods: $INIT_IMAGE_PULL_BACKOFF"
    echo "- ContainerCreating pods: $CONTAINER_CREATING"
    echo "- Failed pods: $FAILED_PODS"
    echo "- CrashLoopBackOff pods: $CRASHLOOP_PODS"
    echo "- Init:CrashLoopBackOff pods: $INIT_CRASHLOOP_PODS"
    echo "- Init:Error pods: $INIT_ERROR_PODS"
    echo "- Problematic pods: $PROBLEMATIC_PODS"
    
    # Provide specific guidance based on the issues found
    if [[ $IMAGE_PULL_BACKOFF -gt 0 ]] || [[ $INIT_IMAGE_PULL_BACKOFF -gt 0 ]]; then
      echo ""
      echo "🔧 Image Pull Issues Detected:"
      echo "The IBM Storage Scale pods are failing to pull images from icr.io"
      echo "This is likely due to missing IBM entitlement credentials"
      echo "Check if the fusion-pullsecret was created with the correct IBM entitlement key"
    fi
    
    if [[ $CRASHLOOP_PODS -gt 0 ]] || [[ $INIT_CRASHLOOP_PODS -gt 0 ]] || [[ $INIT_ERROR_PODS -gt 0 ]]; then
      echo ""
      echo "🔧 CrashLoopBackOff Issues Detected:"
      echo "The IBM Storage Scale pods are crashing during initialization"
      echo "This is often caused by:"
      echo "  - Missing or incorrect image pull secrets"
      echo "  - Insufficient node resources"
      echo "  - Configuration errors in the Cluster resource"
      echo "  - Insufficient quorum nodes (minimum 3 required)"
      echo "Check pod logs for specific error messages"
    fi
    
    # Exit with error code to fail the step
    exit 1
  fi
else
  echo "❌ No IBM Storage Scale pods found - cluster deployment may have failed"
  exit 1
fi
