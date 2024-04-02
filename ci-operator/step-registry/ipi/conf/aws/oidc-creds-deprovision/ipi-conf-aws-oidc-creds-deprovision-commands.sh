#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

infra_name=${NAMESPACE}-${UNIQUE_HASH}
# export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${SHARED_DIR}/aws_minimal_permission" ]]; then
    echo "Setting AWS credential with minimal permision for installer"
    export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_minimal_permission
else
    export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
fi
REGION="${LEASED_RESOURCE}"

# delete credentials infrastructure created by oidc-creds-provision configure step
ccoctl aws delete --name="${infra_name}" --region="${REGION}"
