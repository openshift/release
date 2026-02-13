#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Preparing worker nodes for IBM Storage Scale...'

WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')
WORKER_COUNT=$(echo "$WORKER_NODES" | wc -l)

: "Found $WORKER_COUNT worker nodes"

CreateDirectoryOnNode() {
  local node=$1
  local dir=$2
  
  if oc debug -n default node/"$node" -- chroot /host mkdir -p "$dir" >/dev/null; then
    : "  $dir created on $node"
    return 0
  else
    : "  Failed to create $dir on $node"
    return 1
  fi
}

for node in $WORKER_NODES; do
  : "Processing node: $node"
  
  if ! CreateDirectoryOnNode "$node" "/var/lib/firmware"; then
    : "Failed to prepare node $node"
    exit 1
  fi
  
  if ! CreateDirectoryOnNode "$node" "/var/mmfs/etc"; then
    : "Failed to prepare node $node"
    exit 1
  fi
  if ! CreateDirectoryOnNode "$node" "/var/mmfs/tmp/traces"; then
    : "Failed to prepare node $node"
    exit 1
  fi
  if ! CreateDirectoryOnNode "$node" "/var/mmfs/pmcollector"; then
    : "Failed to prepare node $node"
    exit 1
  fi
  
  : "  Node $node prepared successfully"
done

: 'Worker node preparation complete'
