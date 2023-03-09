#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

key_id=$(head -n 1 ${SHARED_DIR}/aws_kms_key_id)
pending_days=7

if [[ "${key_id}" == "" ]]; then
    echo "ERROR: KMS key is empty."
    exit 1
fi


echo "KMS key $key_id will be delete after $pending_days days."
aws --region $REGION kms schedule-key-deletion --key-id "${key_id}" --pending-window-in-days $pending_days
