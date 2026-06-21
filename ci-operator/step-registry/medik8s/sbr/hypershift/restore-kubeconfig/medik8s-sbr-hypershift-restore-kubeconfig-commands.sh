#!/bin/bash
set -eu -o pipefail

# Restore the management cluster kubeconfig saved by the switch-kubeconfig step.
# Must run as the first post step so hypershift-dump/destroy target the management cluster.
cp "${SHARED_DIR}/management_kubeconfig" "${SHARED_DIR}/kubeconfig"
