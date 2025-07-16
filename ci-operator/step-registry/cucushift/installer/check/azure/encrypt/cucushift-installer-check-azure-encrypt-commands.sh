#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function check_node_root_encryption() {
    local node=$1
    echo "Checking node: $node"

    # Run oc debug, chroot into host, and check lsblk output
    if ! output=$(oc debug node/"$node" -- chroot /host lsblk -o NAME,TYPE,MOUNTPOINTS 2>/dev/null); then
        echo "Failed to get lsblk info from $node"
        return 1
    fi

    # Look for a line with TYPE="crypt" and MOUNTPOINT containing '/'
    if echo "$output" | awk '$2 == "crypt" && $3 ~ /\/( |$)/' | grep -q .; then
        echo "Root partition on $node is encrypted"
        return 0
    else
        echo "Root partition on $node is NOT encrypted!"
        echo "$output"
        return 1
    fi
}

function check_all_nodes() {
    local all_nodes rc=0

    # Get list of nodes
    all_nodes=$(oc get nodes --no-headers | awk '{print $1}')

    for node in $all_nodes; do
        if ! check_node_root_encryption "$node"; then
            (( rc += 1 ))
        fi
    done

    if (( rc > 0 )); then
        echo "One or more nodes do not have encrypted root partitions"
        exit 1
    else
        echo "All nodes have encrypted root partitions"
        exit 0
    fi
}

# Run the check
check_all_nodes

