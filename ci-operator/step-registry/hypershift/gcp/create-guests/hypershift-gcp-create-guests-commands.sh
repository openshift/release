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

/hypershift/bin/create-guests
