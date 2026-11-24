#!/bin/bash

#
# Delete CloudFormation stacks created by AWS UPI.
# The delete will run in parallel the Instance(s) delete,
# then the rest of the infrastructure stacks will be deleted
# in serial.
#

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export REGION="${LEASED_RESOURCE}"
export stacks_file="${SHARED_DIR}/aws_cfn_stacks"

source "${SHARED_DIR}/init-fn.sh" || true

function delete_stack() {
  local stack_name
  stack_name=$1

  # cleaning up after ourselves
  log "[${stack_name}] Sending delete command."
  aws --region "${REGION}" cloudformation delete-stack --stack-name "${stack_name}" &
  wait "$!"

  log "[${stack_name}] Waiting for delete complete."
  aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${stack_name}" &
  wait "$!"

  log "[${stack_name}] Stack deleted."
}

# Enqueue the CloudFormation stack names and delete each one.
delete_stacks() {
  # Parallel delete instances
  log "Starting parallel delete"
  PIDS_COMPUTE=()
  while IFS= read -r stack_name
  do
    case $stack_name in
    *-compute-*|*-bootstrap|*-control-plane)
      delete_stack "$stack_name" &
      PIDS_COMPUTE+=( "$!" )    
    ;;
    *) log "[${stack_name}] ignoring parallel delete for stack" ;
    esac
    sleep 1;
  done <<< "$(tac "${stacks_file}")"

  log "Waiting for parallel delete completed!"
  wait "${PIDS_COMPUTE[@]}"
  log "Parallel delete completed!"

  # Serial delete infrastructure
  log "Starting serial delete."
  while IFS= read -r stack_name
  do
    case $stack_name in
    *-compute-*|*-bootstrap|*-control-plane) log "[${stack_name}] ignoring serial stack delete"; continue ;;
    esac
    delete_stack "$stack_name"
  done <<< "$(tac "${stacks_file}")"
  log "Serial delete completed!"
}

if [[ ! -f "${stacks_file}" ]]; then
  log "WARNING: CloudFormation stack not found. Control file with stack names not found in path: ${stacks_file}"
  exit 0
fi

delete_stacks
