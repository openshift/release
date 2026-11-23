#!/bin/bash

set -exuo pipefail

# Use the nested management cluster kubeconfig
export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
AZURE_OIDC_ISSUER_URL="$(cat /etc/hypershift-ci-jobs-self-managed-azure-oidc/oidc-issuer-url)"
AZURE_ENCRYPTION_KEY_ID="$(cat /etc/hypershift-ci-jobs-self-managed-azure-kms/azure-encryption-key-id)"
: "${AZURE_ENCRYPTION_KEY_ID:?Azure encryption key ID must not be empty}"
export AZURE_OIDC_ISSUER_URL AZURE_ENCRYPTION_KEY_ID
export HYPERSHIFT_BINARY="${HYPERSHIFT_BINARY:-/hypershift/bin/hypershift}"

if [[ -f "${SHARED_DIR}/nodepool_release_images" ]]; then
    source "${SHARED_DIR}/nodepool_release_images"
fi

/hypershift/bin/create-guests
