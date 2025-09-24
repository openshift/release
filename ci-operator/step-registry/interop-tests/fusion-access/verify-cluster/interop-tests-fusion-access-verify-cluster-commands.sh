#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

STORAGE_SCALE_NAMESPACE="${STORAGE_SCALE_NAMESPACE:-ibm-spectrum-scale}"
STORAGE_SCALE_CLUSTER_NAME="${STORAGE_SCALE_CLUSTER_NAME:-ibm-spectrum-scale}"

echo "🔍 Verifying IBM Storage Scale Cluster status..."

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
  
  # Check pod readiness
  READY_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | grep "Running" | wc -l)
  echo "Running pods: $READY_PODS/$POD_COUNT"
  
  # Check for any failed pods
  FAILED_PODS=$(oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | grep -E "(Failed|Error|CrashLoopBackOff)" | wc -l)
  if [[ $FAILED_PODS -gt 0 ]]; then
    echo "⚠️  Found $FAILED_PODS failed pods:"
    oc get pods -n "${STORAGE_SCALE_NAMESPACE}" --no-headers | grep -E "(Failed|Error|CrashLoopBackOff)"
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

echo "✅ IBM Storage Scale Cluster verification completed!"
