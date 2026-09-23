#!/bin/bash

set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

REGION=${REGION:-$LEASED_RESOURCE}

# Special setting for C2S/SC2S
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  REGION=$source_region
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
STACK_NAME="${CLUSTER_NAME}-apps-dns"

stack_status() {
  local output
  if output=$(aws --region "${REGION}" cloudformation describe-stacks \
    --stack-name "${STACK_NAME}" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>&1); then
    printf '%s\n' "${output}"
    return 0
  fi

  if [[ "${output}" == *"does not exist"* ]]; then
    return 2
  fi

  echo "ERROR: Unable to determine status of apps DNS stack ${STACK_NAME}: ${output}" >&2
  return 1
}

wait_for_deletion() {
  if aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}"; then
    echo "Apps DNS stack ${STACK_NAME} deleted successfully"
    return 0
  fi

  local status rc
  if status=$(stack_status); then
    echo "ERROR: Timed out waiting for apps DNS stack ${STACK_NAME} deletion; current status: ${status}" >&2
    return 1
  else
    rc=$?
    if [[ "${rc}" -eq 2 ]]; then
      echo "Apps DNS stack ${STACK_NAME} is already absent"
      return 0
    fi
  fi

  return 1
}

status=""
if status=$(stack_status); then
  case "${status}" in
    DELETE_COMPLETE)
      echo "Apps DNS stack ${STACK_NAME} is already deleted"
      exit 0
      ;;
    DELETE_IN_PROGRESS)
      echo "Apps DNS stack ${STACK_NAME} deletion is already in progress"
      wait_for_deletion
      exit $?
      ;;
  esac
else
  rc=$?
  if [[ "${rc}" -eq 2 ]]; then
    echo "Apps DNS stack ${STACK_NAME} is already absent"
    exit 0
  fi
  exit 1
fi

echo "Deleting apps DNS stack ${STACK_NAME} before cluster deprovisioning"
if ! aws --region "${REGION}" cloudformation delete-stack --stack-name "${STACK_NAME}"; then
  if status=$(stack_status); then
    echo "ERROR: Failed to delete apps DNS stack ${STACK_NAME}; current status: ${status}" >&2
  else
    rc=$?
    if [[ "${rc}" -eq 2 ]]; then
      echo "Apps DNS stack ${STACK_NAME} is already absent"
      exit 0
    fi
  fi
  exit 1
fi

wait_for_deletion
