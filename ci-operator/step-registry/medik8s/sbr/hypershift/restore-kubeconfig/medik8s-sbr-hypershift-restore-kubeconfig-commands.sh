#!/bin/bash
set -eu -o pipefail

# Restore the management cluster kubeconfig saved by the switch-kubeconfig step.
# Must run as the first post step so hypershift-dump/destroy target the management cluster.
# Guard: management_kubeconfig is only written by switch-kubeconfig (test phase).
# If the test phase was never reached (pre-phase failure), skip silently so that
# downstream post steps (hypershift-dump, hypershift-aws-destroy) can still run.
if [[ -f "${SHARED_DIR}/management_kubeconfig" ]]; then
    cp "${SHARED_DIR}/management_kubeconfig" "${SHARED_DIR}/kubeconfig"
else
    echo "management_kubeconfig not found — kubeconfig switch was never made, no restore needed"
fi
