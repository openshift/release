#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "🏷️  Labeling worker nodes for IBM Storage Scale..."

# Get worker nodes before labeling
echo "Worker nodes before labeling:"
oc get nodes -l node-role.kubernetes.io/worker -o custom-columns="NAME:.metadata.name,LABELS:.metadata.labels.scale\.spectrum\.ibm\.com/role" 2>/dev/null || echo "Could not retrieve worker node information"

# Label worker nodes for IBM Storage Scale
echo "Applying storage role labels to worker nodes..."
if oc label nodes -l node-role.kubernetes.io/worker "scale.spectrum.ibm.com/role=storage" --overwrite; then
  echo "✅ Successfully labeled worker nodes for IBM Storage Scale"
else
  echo "❌ Failed to label worker nodes"
  exit 1
fi

# Verify labeling was successful
echo "Verifying node labels..."
LABELED_NODES=$(oc get nodes -l "scale.spectrum.ibm.com/role=storage" --no-headers 2>/dev/null | wc -l)
echo "Found $LABELED_NODES nodes with storage role label"

if [[ $LABELED_NODES -gt 0 ]]; then
  echo "✅ Node labeling verification successful"
  echo "Labeled nodes:"
  oc get nodes -l "scale.spectrum.ibm.com/role=storage" -o custom-columns="NAME:.metadata.name,ROLE:.metadata.labels.scale\.spectrum\.ibm\.com/role,STATUS:.status.conditions[?(@.type=='Ready')].status" 2>/dev/null || echo "Could not retrieve labeled node details"
else
  echo "❌ No nodes found with storage role label"
  echo "Checking for any labeling issues..."
  oc get nodes -l node-role.kubernetes.io/worker -o yaml | grep -A 5 -B 5 "scale.spectrum.ibm.com" || echo "No IBM Storage Scale labels found on worker nodes"
  exit 1
fi

# Check for any labeling events
echo "Checking for node labeling events..."
oc get events --all-namespaces --sort-by='.lastTimestamp' | grep -i "label\|storage" | tail -5 || echo "No recent labeling events found"

echo "✅ Worker node labeling completed successfully!"
