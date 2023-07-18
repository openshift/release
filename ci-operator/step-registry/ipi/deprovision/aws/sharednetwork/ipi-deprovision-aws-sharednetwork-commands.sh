#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"

function delete_stack() {
  local stack_file_name
  stack_file_name=$1

  if test ! -f "${SHARED_DIR}/${stack_file_name}"
  then
    echo "Stack file ${stack_file_name} unknown or not found, so unable to tear down."
    return
  fi

  stack_name="$(cat "${SHARED_DIR}/${stack_file_name}")"

  # cleaning up after ourselves
  echo "Deleting CloudFormation stack ${stack_name}"
  aws --region "${REGION}" cloudformation delete-stack --stack-name "${stack_name}" &
  wait "$!"

  aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
  wait "$!"

  echo "${stack_name} stack delete complete"
}

if [[ "${AWS_EDGE_POOL_ENABLED-}" == "yes" ]]; then
  delete_stack "sharednetwork_stackname_localzone"
fi

delete_stack "sharednetworkstackname"
