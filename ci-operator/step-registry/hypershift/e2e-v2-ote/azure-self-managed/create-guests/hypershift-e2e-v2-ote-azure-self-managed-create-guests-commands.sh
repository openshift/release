#!/bin/bash

set -exuo pipefail

# Use the nested management cluster kubeconfig
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
export HYPERSHIFT_BINARY="${HYPERSHIFT_BINARY:-/hypershift/bin/hypershift}"

if [[ -f "${SHARED_DIR}/nodepool_release_images" ]]; then
    source "${SHARED_DIR}/nodepool_release_images"
fi

/hypershift/bin/create-guests
