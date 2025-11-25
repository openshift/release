#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🔍 Checking worker nodes..."

# Verify minimum worker node count for quorum
WORKER_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

if [[ $WORKER_NODE_COUNT -lt 3 ]]; then
  echo "⚠️  WARNING: Only $WORKER_NODE_COUNT worker nodes (minimum 3 required for quorum)"
  echo "IBM Storage Scale requires at least 3 nodes for quorum"
else
  echo "✅ Found $WORKER_NODE_COUNT worker nodes (quorum requirements met)"
fi

echo ""
echo "Worker nodes:"
oc get nodes -l node-role.kubernetes.io/worker
