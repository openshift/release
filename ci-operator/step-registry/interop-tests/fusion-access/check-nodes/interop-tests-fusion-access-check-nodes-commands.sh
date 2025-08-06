#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "🔍 Checking worker nodes..."

WORKER_NODE_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | wc -l)

if [[ $WORKER_NODE_COUNT -lt 3 ]]; then
  echo "⚠️  WARNING: Only $WORKER_NODE_COUNT worker nodes (minimum 3 required for quorum)"
else
  echo "✅ Found $WORKER_NODE_COUNT worker nodes (quorum requirements met)"
fi

oc get nodes -l node-role.kubernetes.io/worker
