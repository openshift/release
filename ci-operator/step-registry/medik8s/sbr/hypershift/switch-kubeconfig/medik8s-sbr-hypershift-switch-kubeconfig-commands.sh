#!/bin/bash
set -eu -o pipefail

# Save management cluster kubeconfig so the restore step can put it back before
# the post phase runs (hypershift-dump/destroy need the management cluster).
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/management_kubeconfig"

# ci-operator points KUBECONFIG at ${SHARED_DIR}/kubeconfig for every step.
# Overwriting the file makes all subsequent test steps target the hosted cluster.
cp "${SHARED_DIR}/nested_kubeconfig" "${SHARED_DIR}/kubeconfig"
