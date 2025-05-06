#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

infra_name=${NAMESPACE}-${UNIQUE_HASH}
REGION="${LEASED_RESOURCE}"

if [[ ${AWS_CCOCTL_USE_MINIMAL_PERMISSIONS} == "yes" ]]; then
  if [[ ! -f "${SHARED_DIR}/aws_minimal_permission_ccoctl" ]]; then
    echo "ERROR: AWS_CCOCTL_USE_MINIMAL_PERMISSIONS is enabled, but the credential file \"aws_minimal_permission_ccoctl\" is missing."
    echo "ERROR: Note, the credential file is created by chain \"aws-provision-iam-user-minimal-permission\", please check."
    echo "Exit now."
    exit 1
  fi
  echo "Setting AWS credential with minimal permision for ccoctl"
  export AWS_SHARED_CREDENTIALS_FILE=${SHARED_DIR}/aws_minimal_permission_ccoctl
else
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

# delete credentials infrastructure created by oidc-creds-provision configure step
ccoctl aws delete --name="${infra_name}" --region="${REGION}"
