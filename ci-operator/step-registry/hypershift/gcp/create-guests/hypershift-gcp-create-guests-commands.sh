#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
export HYPERSHIFT_BINARY="${HYPERSHIFT_BINARY:-/hypershift/bin/hypershift}"
# GCP Application Default Credentials for the hypershift CLI (WIF credential
# written by the hypershift-gcp-wif-auth step).
export GOOGLE_APPLICATION_CREDENTIALS="${SHARED_DIR}/wif-cred.json"

if [[ -f "${SHARED_DIR}/nodepool_release_images" ]]; then
    source "${SHARED_DIR}/nodepool_release_images"
fi

if [[ -f "${SHARED_DIR}/test-plan.yaml" ]]; then
    export TEST_PLAN="${SHARED_DIR}/test-plan.yaml"
fi

# Keep this step compatible with HyperShift branches that predate the
# resource-label flag while enabling resource-label coverage where supported.
resource_label_help="$("${HYPERSHIFT_BINARY}" create cluster gcp --help 2>&1 || true)"
if [[ "${resource_label_help}" == *"--resource-labels"* ]]; then
    export EXTRA_ARGS="${EXTRA_ARGS} --resource-labels hypershift-e2e-resource-labels=enabled"
fi

/hypershift/bin/create-guests
