#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

#
# Delete CloudFormation stacks created by AWS UPI.
# The delete will run in parallel the Instance(s) delete,
# then the rest of the infrastructure stacks will be deleted
# in serial.
#

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

function delete_stack() {
  local stack_name
  stack_name=$1

  # cleaning up after ourselves
  echo_date "[${stack_name}] Sending delete command."
  aws --region "${REGION}" cloudformation delete-stack --stack-name "${stack_name}" &
  wait "$!"

  echo_date "[${stack_name}] Waiting for delete complete."
  aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
  wait "$!"

  echo_date "[${stack_name}] Stack deleted."
}

# Enqueue the CloudFormation stack names and delete each one.
delete_stacks() {
  local stacks_file="${SHARED_DIR}/aws_cfn_stacks"
  if [[ ! -f "${stacks_file}" ]]; then
    echo_date "WARNING: CloudFormation stack not found. Control file with stack names not found in path: ${stacks_file}"
    return
  fi

  # Parallel delete instances
  echo_date "Starting parallel delete"
  PIDS_COMPUTE=()
  while IFS= read -r stack_name
  do
    case $stack_name in
    *-compute-*|*-bootstrap|*-control-plane)
      delete_stack "$stack_name" &
      PIDS_COMPUTE+=( "$!" )    
    ;;
    *) echo_date "[${stack_name}] ignoring parallel delete for stack" ;
    esac
    sleep 1;
  done <<< "$(tac "${stacks_file}")"
  echo_date "Waiting for parallel delete completed!"
  wait "${PIDS_COMPUTE[@]}"
  echo_date "Parallel delete completed!"

  # Serial delete infrastructure
  echo_date "Starting serial delete."
  while IFS= read -r stack_name
  do
    case $stack_name in
    *-compute-*|*-bootstrap|*-control-plane) echo_date "[${stack_name}] ignoring serial stack delete"; continue ;;
    esac
    delete_stack "$stack_name"
  done <<< "$(tac "${stacks_file}")"
  echo_date "Serial delete completed!"
}

delete_stacks