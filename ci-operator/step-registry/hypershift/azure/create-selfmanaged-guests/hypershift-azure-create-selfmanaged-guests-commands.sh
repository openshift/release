#!/bin/bash

set -exuo pipefail

# Use the nested management cluster kubeconfig
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
export HYPERSHIFT_BINARY="${HYPERSHIFT_BINARY:-/hypershift/bin/hypershift}"

if [[ -f "${SHARED_DIR}/nodepool_release_images" ]]; then
    source "${SHARED_DIR}/nodepool_release_images"
fi

if [[ -f "${SHARED_DIR}/test-plan.yaml" ]]; then
    export TEST_PLAN="${SHARED_DIR}/test-plan.yaml"
fi

/hypershift/bin/create-guests
