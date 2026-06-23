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

if ! [[ "${EXPECTED_NODES}" =~ ^[0-9]+$ ]] || [[ "${EXPECTED_NODES}" -lt 1 ]]; then
    log "ERROR: HYPERSHIFT_NODE_COUNT must be a positive integer (got: ${EXPECTED_NODES})"
    exit 1
fi

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
    if [[ $elapsed -ge $TIMEOUT ]]; then
        log "ERROR: Timed out after ${TIMEOUT}s waiting for NodePool rotation"
        oc get nodes -o wide
        oc get nodes -o json | jq '.items[] | {name: .metadata.name, taints: .spec.taints}'
        exit 1
    fi
    sleep "${INTERVAL}"
    elapsed=$((elapsed + INTERVAL))
done

ready_count=$(oc get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)
log "${ready_count} node(s) Ready and at current revision"

if [[ "$ready_count" -lt "$EXPECTED_NODES" ]]; then
    log "ERROR: expected ${EXPECTED_NODES} Ready node(s) but found ${ready_count}"
    oc get nodes -o wide
    exit 1
fi

# HyperShift drains old nodes (SchedulingDisabled) before deleting them. The outdated-revision
# taint is removed after drain completes, so the taint loop above can exit while a stale
# cordoned node still exists in the API. Wait until total node count == EXPECTED_NODES so that
# no cordoned remnant can be selected as a test target.
log "Waiting for stale cordoned nodes to be removed (total must equal ${EXPECTED_NODES}, timeout 5m)..."
elapsed=0
while true; do
    total=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$total" -le "$EXPECTED_NODES" ]]; then
        log "Total node count is ${total} — no stale nodes remaining"
        break
    fi
    if [[ $elapsed -ge 300 ]]; then
        log "WARNING: timed out waiting for stale nodes to be deleted (total=${total}, expected=${EXPECTED_NODES})"
        oc get nodes -o wide
        break
    fi
    log "Total nodes=${total}, expected=${EXPECTED_NODES} — waiting for old node(s) to be deleted (${elapsed}s)..."
    sleep 15
    elapsed=$((elapsed + 15))
done
