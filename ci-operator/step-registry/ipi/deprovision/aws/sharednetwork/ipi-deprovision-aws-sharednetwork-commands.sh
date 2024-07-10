#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"

function delete_stack() {
  local stack_name
  stack_name=$1

  # cleaning up after ourselves
  echo "Deleting CloudFormation stack: ${stack_name}"
  aws --region "${REGION}" cloudformation delete-stack --stack-name "${stack_name}" &
  wait "$!"

  echo "Stack delete command sent. Waiting for complete."
  aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
  wait "$!"

  echo "${stack_name} stack delete complete"
}

# Enqueue the CloudFormation stack names and delete each one.
delete_stacks() {
  local stacks_file="${SHARED_DIR}/deprovision_stacks"
  if [[ ! -f "${stacks_file}" ]]; then
    echo "WARNING No CloudFormation stack was found. Control file with stack names was not found in path: ${stacks_file}"
    return
  fi
  while IFS= read -r stack_name
  do
    delete_stack "$stack_name"
  done <<< "$(tac "${stacks_file}")"
}

delete_stacks