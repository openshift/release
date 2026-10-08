#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
export HYPERSHIFT_BINARY="${HYPERSHIFT_BINARY:-/hypershift/bin/hypershift}"
export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"

if [[ -f "${SHARED_DIR}/nodepool_release_images" ]]; then
    source "${SHARED_DIR}/nodepool_release_images"
fi

if [[ -f "${SHARED_DIR}/test-plan.yaml" ]]; then
    export TEST_PLAN="${SHARED_DIR}/test-plan.yaml"
fi

# Storage KMS encryption: only forward the KMS key alias when the hypershift
# binary supports the --initial-storage-volumes-kms-key flag.
if [[ -n "${HYPERSHIFT_STORAGE_KMS_KEY_ALIAS:-}" ]]; then
    # Capture the help output first, then search the captured string. Piping the
    # binary directly into "grep -q" would close the pipe on the first match and
    # send SIGPIPE to hypershift, which under "set -o pipefail" fails the pipeline
    # and would wrongly report the flag as unsupported.
    kms_help_output="$("${HYPERSHIFT_BINARY}" create cluster aws --help 2>&1 || true)"
    if [[ "${kms_help_output}" == *initial-storage-volumes-kms-key* ]]; then
        echo "hypershift supports --initial-storage-volumes-kms-key; forwarding HYPERSHIFT_STORAGE_KMS_KEY_ALIAS=${HYPERSHIFT_STORAGE_KMS_KEY_ALIAS}"
        export HYPERSHIFT_STORAGE_KMS_KEY_ALIAS
    else
        echo "hypershift binary does not support --initial-storage-volumes-kms-key; unsetting HYPERSHIFT_STORAGE_KMS_KEY_ALIAS"
        unset HYPERSHIFT_STORAGE_KMS_KEY_ALIAS
    fi
fi

# Etcd KMS encryption: forward the key alias as HYPERSHIFT_ETCD_KMS_KEY_ARN so
# that the kms-reencryption ClusterSpec variant can pass it as --kms-key-arn.
# The AWS KMS SDK accepts both full ARNs and alias identifiers (alias/<name>).
if [[ -n "${HYPERSHIFT_ETCD_KMS_KEY_ALIAS:-}" ]]; then
    echo "Forwarding HYPERSHIFT_ETCD_KMS_KEY_ALIAS=${HYPERSHIFT_ETCD_KMS_KEY_ALIAS} as HYPERSHIFT_ETCD_KMS_KEY_ARN"
    export HYPERSHIFT_ETCD_KMS_KEY_ARN="${HYPERSHIFT_ETCD_KMS_KEY_ALIAS}"
fi

/hypershift/bin/create-guests
