#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

function delete_kms_key()
{
    local key_id=$1
    local pending_days=7

    echo "KMS key $key_id will be delete after $pending_days days."
    aws --region $REGION kms schedule-key-deletion --key-id "${key_id}" --pending-window-in-days $pending_days
}

for key_id_file in ${SHARED_DIR}/aws_kms_key_id*;
do
    echo "Checking ${key_id_file}"
    key_id=$(cat ${key_id_file})
    if [[ "${key_id}" == "" ]]; then
        continue
    fi
    delete_kms_key ${key_id}
done
