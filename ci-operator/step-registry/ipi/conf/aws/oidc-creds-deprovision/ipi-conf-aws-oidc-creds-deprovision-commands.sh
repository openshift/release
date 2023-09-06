#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

infra_name=${NAMESPACE}-${UNIQUE_HASH}
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

# delete credentials infrastructure created by oidc-creds-provision configure step
ccoctl aws delete --name="${infra_name}" --region="${REGION}"
