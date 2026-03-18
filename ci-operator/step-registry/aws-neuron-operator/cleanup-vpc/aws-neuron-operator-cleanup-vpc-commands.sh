#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${REGION:-$LEASED_RESOURCE}"
STACK_NAME="${NAMESPACE}-${UNIQUE_HASH}-vpc"

echo "Checking for pre-existing VPC stack: ${STACK_NAME} in ${REGION}"

stack_status=""
if aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" > /tmp/stack_info.json 2>/dev/null; then
  stack_status=$(jq -r '.Stacks[0].StackStatus' /tmp/stack_info.json)
  echo "Found existing stack ${STACK_NAME} in status: ${stack_status}"
else
  echo "No existing stack found, nothing to clean up"
  exit 0
fi

case "${stack_status}" in
  DELETE_IN_PROGRESS)
    echo "Stack deletion already in progress, waiting for completion..."
    aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" &
    wait "$!"
    echo "Stack deletion complete"
    ;;
  DELETE_COMPLETE)
    echo "Stack already deleted, nothing to do"
    ;;
  *)
    echo "Deleting stale stack ${STACK_NAME} (status: ${stack_status})..."
    aws --region "${REGION}" cloudformation delete-stack --stack-name "${STACK_NAME}" &
    wait "$!"
    echo "Delete initiated, waiting for completion..."
    aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" &
    wait "$!"
    echo "Stale stack deleted successfully"
    ;;
esac
