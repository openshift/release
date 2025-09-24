#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "🔍 Checking available worker nodes for IBM Storage Scale..."

WORKER_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l)
echo "Found $WORKER_NODE_COUNT worker nodes"

if [[ $WORKER_NODE_COUNT -lt 3 ]]; then
  echo "⚠️  WARNING: Only $WORKER_NODE_COUNT worker nodes available, but IBM Storage Scale requires at least 3 nodes for quorum"
  echo "Proceeding with available nodes, but deployment may not be fully functional"
else
  echo "✅ Sufficient worker nodes available for IBM Storage Scale quorum"
fi

# Get detailed node information
echo "Worker node details:"
oc get nodes -l node-role.kubernetes.io/worker -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,ROLES:.metadata.labels.node-role\.kubernetes\.io/worker" 2>/dev/null || echo "Could not retrieve worker node details"

# Check control plane nodes as well
CONTROL_PLANE_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l)
echo "Found $CONTROL_PLANE_NODE_COUNT control plane nodes"

# Total node count
TOTAL_NODE_COUNT=$((WORKER_NODE_COUNT + CONTROL_PLANE_NODE_COUNT))
echo "Total cluster nodes: $TOTAL_NODE_COUNT"

# Provide recommendations based on node count
if [[ $WORKER_NODE_COUNT -lt 3 ]]; then
  echo "📋 RECOMMENDATIONS:"
  echo "  - Consider using a cluster with at least 3 worker nodes for production IBM Storage Scale deployment"
  echo "  - Current configuration may work for testing but may not be fully functional"
  echo "  - Quorum requirements may not be met with current node count"
elif [[ $WORKER_NODE_COUNT -eq 3 ]]; then
  echo "📋 RECOMMENDATIONS:"
  echo "  - Minimum quorum requirements met with 3 worker nodes"
  echo "  - Consider additional nodes for better fault tolerance"
else
  echo "📋 RECOMMENDATIONS:"
  echo "  - Excellent node count for IBM Storage Scale deployment"
  echo "  - Sufficient nodes for quorum and fault tolerance"
fi

echo "✅ Worker node availability check completed!"
