#!/bin/bash

#
# Wait for CCM to initialize all worker nodes by removing the uninitialized taint.
# This step addresses a timing issue where CCM may take longer to initialize nodes
# in UPI setups, causing install-complete to fail when operators cannot schedule pods.
#

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/init-fn.sh" || true

log "Waiting for CCM to initialize worker nodes..."

# Maximum wait time: 30 minutes (180 iterations * 10 seconds)
MAX_ITERATIONS=180
ITERATION=0
CHECK_INTERVAL=10

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
  log "Iteration $((ITERATION + 1))/$MAX_ITERATIONS - Checking node initialization status..."

  # Get all worker nodes
  WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | awk '{print $1}' || echo "")

  if [ -z "$WORKER_NODES" ]; then
    log "No worker nodes found yet, waiting..."
    ITERATION=$((ITERATION + 1))
    sleep $CHECK_INTERVAL
    continue
  fi

  # Count total workers
  TOTAL_WORKERS=$(echo "$WORKER_NODES" | wc -l)
  log "Found $TOTAL_WORKERS worker nodes"

  # Check each worker for the uninitialized taint
  UNINITIALIZED_COUNT=0
  INITIALIZED_NODES=""
  UNINITIALIZED_NODES=""

  for node in $WORKER_NODES; do
    # Check if node has the uninitialized taint
    if oc get node "$node" -o jsonpath='{.spec.taints[?(@.key=="node.cloudprovider.kubernetes.io/uninitialized")].key}' 2>/dev/null | grep -q "uninitialized"; then
      UNINITIALIZED_COUNT=$((UNINITIALIZED_COUNT + 1))
      UNINITIALIZED_NODES="$UNINITIALIZED_NODES $node"
      log "  - Node $node: ❌ UNINITIALIZED (taint still present)"
    else
      INITIALIZED_NODES="$INITIALIZED_NODES $node"
      log "  - Node $node: ✅ INITIALIZED (taint removed)"
    fi
  done

  log "Status: $((TOTAL_WORKERS - UNINITIALIZED_COUNT))/$TOTAL_WORKERS workers initialized"

  # If all workers are initialized, we're done
  if [ $UNINITIALIZED_COUNT -eq 0 ]; then
    log "✅ SUCCESS: All worker nodes have been initialized by CCM!"
    log "Initialized nodes:$INITIALIZED_NODES"
    exit 0
  fi

  # Show CCM logs for debugging
  if [ $((ITERATION % 6)) -eq 0 ]; then  # Every minute
    log "CCM pod status:"
    oc get pods -n openshift-cloud-controller-manager -l k8s-app=aws-cloud-controller-manager --no-headers 2>/dev/null || echo "CCM pods not found"

    log "Recent CCM logs (last 10 lines):"
    oc logs -n openshift-cloud-controller-manager -l k8s-app=aws-cloud-controller-manager --tail=10 2>/dev/null || echo "Could not fetch CCM logs"
  fi

  log "Waiting ${CHECK_INTERVAL}s for CCM to initialize remaining nodes..."
  ITERATION=$((ITERATION + 1))
  sleep $CHECK_INTERVAL
done

# Timeout reached
log "❌ TIMEOUT: CCM failed to initialize all worker nodes within $((MAX_ITERATIONS * CHECK_INTERVAL / 60)) minutes"
log "Uninitialized nodes:$UNINITIALIZED_NODES"
log "Initialized nodes:$INITIALIZED_NODES"

log "Collecting final CCM logs for debugging:"
oc logs -n openshift-cloud-controller-manager -l k8s-app=aws-cloud-controller-manager --tail=50 2>/dev/null || echo "Could not fetch CCM logs"

log "Node details:"
for node in $UNINITIALIZED_NODES; do
  log "=== Node $node ==="
  oc get node "$node" -o yaml 2>/dev/null || echo "Could not get node details"
done

exit 1
