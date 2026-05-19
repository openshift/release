#!/bin/bash

set -exuo pipefail

# Use the nested management cluster kubeconfig
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
export HYPERSHIFT_BINARY="${HYPERSHIFT_BINARY:-/hypershift/bin/hypershift}"

/hypershift/bin/create-guests
