#!/bin/bash
set -eu -o pipefail

# apply-image-sources patches the HostedCluster imageContentSources, which triggers
# the HyperShift NodePool controller to rotate all worker nodes.  The NodePool
# AllNodesHealthy wait in that step can complete while rotation is still in progress,
# because the NodePool controller and node replacement operate independently.  Rotating nodes lose
# their ODF labels, so odf-prepare-cluster must not run until all nodes have finished
# their revision update.
#
# This step waits for all three invariants to hold simultaneously:
#   1. At least EXPECTED_NODES worker nodes are Ready.
#   2. No node carries the node.cluster.x-k8s.io/outdated-revision taint (rotation done).
#   3. Total node count <= EXPECTED_NODES (stale cordoned nodes have been deleted).

declare EXPECTED_NODES="${HYPERSHIFT_NODE_COUNT:-3}"
declare TIMEOUT=1200  # 20 minutes
declare INTERVAL=15

log() { echo "[$(date --utc +%FT%T.%3NZ)] $*"; }

if ! [[ "${EXPECTED_NODES}" =~ ^[0-9]+$ ]] || [[ "${EXPECTED_NODES}" -lt 1 ]]; then
    log "ERROR: HYPERSHIFT_NODE_COUNT must be a positive integer (got: ${EXPECTED_NODES})"
    exit 1
fi

log "Waiting for ${EXPECTED_NODES} Ready node(s) at current revision (timeout ${TIMEOUT}s)..."
elapsed=0
while true; do
    node_json=$(oc get nodes -o json 2>/dev/null)

    total=$(echo "$node_json" | jq '.items | length')
    ready=$(echo "$node_json" | jq '[.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status == "True"))] | length')
    outdated=$(echo "$node_json" | jq '[.items[] | select((.spec.taints // []) | map(.key) | contains(["node.cluster.x-k8s.io/outdated-revision"]))] | length')

    if [[ "$ready" -ge "$EXPECTED_NODES" ]] && [[ "$outdated" -eq 0 ]] && [[ "$total" -le "$EXPECTED_NODES" ]]; then
        log "All conditions met: ${ready} Ready, ${outdated} outdated, ${total} total (expected ${EXPECTED_NODES})"
        break
    fi

    if [[ $elapsed -ge $TIMEOUT ]]; then
        log "ERROR: Timed out after ${TIMEOUT}s — ${ready}/${EXPECTED_NODES} Ready, ${outdated} outdated-revision, ${total} total"
        oc get nodes -o wide
        oc get nodes -o json | jq '.items[] | {name: .metadata.name, taints: .spec.taints}'
        exit 1
    fi

    log "Waiting: ${ready}/${EXPECTED_NODES} Ready, ${outdated} outdated-revision, ${total} total (${elapsed}s elapsed)"
    sleep "${INTERVAL}"
    elapsed=$((elapsed + INTERVAL))
done
