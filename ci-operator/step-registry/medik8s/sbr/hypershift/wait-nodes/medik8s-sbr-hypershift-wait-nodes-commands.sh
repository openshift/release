#!/bin/bash
set -eu -o pipefail

# apply-image-sources patches the HostedCluster imageContentSources, which triggers
# the Hypershift NodePool controller to rotate all worker nodes.  The MCP "Updated"
# wait in that step can complete while rotation is still in progress, because MCO and
# the NodePool controller operate independently.  Rotating nodes lose their ODF labels,
# so odf-prepare-cluster must not run until all nodes have finished their revision update.
#
# This step waits for:
#   1. All expected worker nodes to be Ready.
#   2. No node to carry the node.cluster.x-k8s.io/outdated-revision taint (rotation done).

declare EXPECTED_NODES="${HYPERSHIFT_NODE_COUNT:-3}"
declare TIMEOUT=1200  # 20 minutes
declare INTERVAL=15

log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

log "Waiting for ${EXPECTED_NODES} node(s) to be Ready (timeout 15m)..."
oc wait nodes --all --for=condition=Ready --timeout=15m

log "Waiting for NodePool rotation to complete (no outdated-revision taint, timeout ${TIMEOUT}s)..."
elapsed=0
while true; do
    outdated=$(oc get nodes -o json | \
        jq '[.items[] | select((.spec.taints // []) | map(.key) | contains(["node.cluster.x-k8s.io/outdated-revision"]))] | length')
    if [[ "$outdated" -eq 0 ]]; then
        log "All nodes are at current revision — NodePool rotation complete"
        break
    fi
    log "${outdated} node(s) still have outdated-revision taint (${elapsed}s elapsed)..."
    sleep "${INTERVAL}"
    elapsed=$((elapsed + INTERVAL))
    if [[ $elapsed -ge $TIMEOUT ]]; then
        log "ERROR: Timed out after ${TIMEOUT}s waiting for NodePool rotation"
        oc get nodes -o wide
        oc get nodes -o json | jq '.items[] | {name: .metadata.name, taints: .spec.taints}'
        exit 1
    fi
done

ready_count=$(oc get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
log "${ready_count} node(s) Ready and at current revision"
