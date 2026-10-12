#!/bin/bash

#
# Wait for CCM to initialize all nodes by:
# 1. Checking that all nodes have providerID set
# 2. Checking that CCM removed the uninitialized taint
#
# This step addresses a timing issue where CCM may take longer to initialize nodes
# in Platform External (UPI with external CCM) setups, causing install-complete to
# fail when operators cannot schedule pods on uninitialized nodes.
#

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/init-fn.sh" || true

# Only run when CCM is enabled
if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED:-}" != "yes" ]]; then
  log "ℹ️  Skipping CCM node initialization check - PLATFORM_EXTERNAL_CCM_ENABLED != yes"
  log "CCM node initialization is only verified when CCM is enabled on Platform External installations"
  exit 0
fi

log "Waiting for CCM to initialize all cluster nodes..."

# Maximum wait time: 30 minutes (180 iterations * 10 seconds)
MAX_ITERATIONS=180
ITERATION=0
CHECK_INTERVAL=10

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
  log "Iteration $((ITERATION + 1))/$MAX_ITERATIONS - Checking node initialization status..."

  # Get all nodes (both masters and workers)
  ALL_NODES=$(oc get nodes --no-headers 2>/dev/null | awk '{print $1}' || echo "")

  if [ -z "$ALL_NODES" ]; then
    log "No nodes found yet, waiting..."
    ITERATION=$((ITERATION + 1))
    sleep $CHECK_INTERVAL
    continue
  fi

  # Count total nodes
  TOTAL_NODES=$(echo "$ALL_NODES" | wc -l)
  log "Found $TOTAL_NODES nodes in cluster"

  # Check each node for provider ID and initialization status
  MISSING_PROVIDERID_COUNT=0
  UNINITIALIZED_COUNT=0
  NODES_MISSING_PROVIDERID=""
  NODES_UNINITIALIZED=""
  NODES_READY=""

  for node in $ALL_NODES; do
    NODE_ROLE=$(oc get node "$node" --no-headers 2>/dev/null | awk '{print $3}' || echo "unknown")

    # Check if node has providerID set
    PROVIDER_ID=$(oc get node "$node" -o jsonpath='{.spec.providerID}' 2>/dev/null || echo "")

    if [ -z "$PROVIDER_ID" ]; then
      MISSING_PROVIDERID_COUNT=$((MISSING_PROVIDERID_COUNT + 1))
      NODES_MISSING_PROVIDERID="$NODES_MISSING_PROVIDERID $node"
      log "  - Node $node ($NODE_ROLE): ❌ MISSING providerID"
      continue
    fi

    # Check if node has the uninitialized taint
    if oc get node "$node" -o jsonpath='{.spec.taints[?(@.key=="node.cloudprovider.kubernetes.io/uninitialized")].key}' 2>/dev/null | grep -q "uninitialized"; then
      UNINITIALIZED_COUNT=$((UNINITIALIZED_COUNT + 1))
      NODES_UNINITIALIZED="$NODES_UNINITIALIZED $node"
      log "  - Node $node ($NODE_ROLE): ⚠️  Has providerID but UNINITIALIZED (taint present)"
    else
      NODES_READY="$NODES_READY $node"
      log "  - Node $node ($NODE_ROLE): ✅ Initialized (providerID: $PROVIDER_ID)"
    fi
  done

  READY_COUNT=$((TOTAL_NODES - MISSING_PROVIDERID_COUNT - UNINITIALIZED_COUNT))
  log "Status: $READY_COUNT/$TOTAL_NODES nodes fully initialized"

  if [ $MISSING_PROVIDERID_COUNT -gt 0 ]; then
    log "  - $MISSING_PROVIDERID_COUNT nodes missing providerID:$NODES_MISSING_PROVIDERID"
  fi

  if [ $UNINITIALIZED_COUNT -gt 0 ]; then
    log "  - $UNINITIALIZED_COUNT nodes with uninitialized taint:$NODES_UNINITIALIZED"
  fi

  # If all nodes are initialized with providerID, we're done
  if [ $MISSING_PROVIDERID_COUNT -eq 0 ] && [ $UNINITIALIZED_COUNT -eq 0 ]; then
    log "✅ SUCCESS: All $TOTAL_NODES nodes have providerID set and have been initialized by CCM!"
    log "Ready nodes:$NODES_READY"
    exit 0
  fi

  # Show CCM logs for debugging
  if [ $((ITERATION % 6)) -eq 0 ]; then  # Every minute
    log "CCM pod status:"
    oc get pods -n openshift-cloud-controller-manager --no-headers 2>/dev/null || echo "CCM pods not found"

    log "Recent CCM logs (last 10 lines):"
    oc logs -n openshift-cloud-controller-manager -l infrastructure.openshift.io/cloud-controller-manager --tail=10 2>/dev/null || echo "Could not fetch CCM logs"
  fi

  log "Waiting ${CHECK_INTERVAL}s for CCM to initialize remaining nodes..."
  ITERATION=$((ITERATION + 1))
  sleep $CHECK_INTERVAL
done

# Timeout reached
log "❌ TIMEOUT: CCM failed to initialize all nodes within $((MAX_ITERATIONS * CHECK_INTERVAL / 60)) minutes"

if [ -n "$NODES_MISSING_PROVIDERID" ]; then
  log "Nodes missing providerID:$NODES_MISSING_PROVIDERID"
fi

if [ -n "$NODES_UNINITIALIZED" ]; then
  log "Nodes with uninitialized taint:$NODES_UNINITIALIZED"
fi

if [ -n "$NODES_READY" ]; then
  log "Nodes successfully initialized:$NODES_READY"
fi

log "Collecting final CCM logs for debugging:"
oc logs -n openshift-cloud-controller-manager -l infrastructure.openshift.io/cloud-controller-manager --tail=50 2>/dev/null || echo "Could not fetch CCM logs"

log "Node details for failed nodes:"
for node in $NODES_MISSING_PROVIDERID $NODES_UNINITIALIZED; do
  log "=== Node $node ==="
  oc get node "$node" -o yaml 2>/dev/null || echo "Could not get node details"
done

exit 1
