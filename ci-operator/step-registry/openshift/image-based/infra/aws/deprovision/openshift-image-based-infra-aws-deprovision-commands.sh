#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'save_stack_events_to_artifacts' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION=${EC2_REGION:-$LEASED_RESOURCE}

# Special setting for C2S/SC2S
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  REGION=$source_region
fi

stack_name=""

function save_stack_events_to_artifacts()
{
  set +o errexit
  if [[ -n "${stack_name}" ]]; then
    aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${stack_name}" --output json \
      > "${ARTIFACT_DIR}/stack-events-${stack_name}.json" 2>/dev/null
  fi
  set -o errexit
}

function dump_stack_failure() {
  local name="$1"

  echo "==== CloudFormation failure details for stack ${name} ===="
  aws --region "${REGION}" cloudformation describe-stacks --stack-name "${name}" \
    --query 'Stacks[0].[StackStatus,StackStatusReason]' --output table 2>/dev/null || true
  aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${name}" \
    --query 'StackEvents[0:40].[Timestamp,LogicalResourceId,ResourceType,ResourceStatus,ResourceStatusReason]' \
    --output table 2>/dev/null || true
}

function stack_status() {
  aws --region "${REGION}" cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true
}

function get_failed_resources() {
  # Returns the list of resources that failed to delete
  local name="$1"
  aws --region "${REGION}" cloudformation describe-stack-events --stack-name "${name}" \
    --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" --output text 2>/dev/null || true
}

function force_cleanup_stack_resources() {
  # Best-effort cleanup for resources that commonly block stack deletion (DELETE_FAILED).
  local name="$1"

  local failed_resources
  failed_resources="$(get_failed_resources "${name}")"
  echo "Resources that failed to delete: ${failed_resources:-none}"

  # Get VPC ID from stack resources
  local vpc_id
  vpc_id="$(aws --region "${REGION}" cloudformation describe-stack-resources --stack-name "${name}" \
    --query 'StackResources[?ResourceType==`AWS::EC2::VPC`].PhysicalResourceId' --output text 2>/dev/null || true)"

  # Terminate any EC2 instances first (they block many other resources)
  local instance_id
  instance_id="$(aws --region "${REGION}" cloudformation describe-stack-resources --stack-name "${name}" \
    --query 'StackResources[?ResourceType==`AWS::EC2::Instance`].PhysicalResourceId' --output text 2>/dev/null || true)"

  if [[ -n "${instance_id}" && "${instance_id}" != "None" ]]; then
    echo "Terminating instance blocking stack deletion: ${instance_id}"
    aws --region "${REGION}" ec2 terminate-instances --instance-ids "${instance_id}" >/dev/null 2>&1 || true
    aws --region "${REGION}" ec2 wait instance-terminated --instance-ids "${instance_id}" >/dev/null 2>&1 || true
  fi

  # If VPC Gateway Attachment is blocking, try to detach the Internet Gateway manually
  if [[ "${failed_resources}" == *"RHELGatewayAttachment"* ]] && [[ -n "${vpc_id}" && "${vpc_id}" != "None" ]]; then
    local igw_id
    igw_id="$(aws --region "${REGION}" cloudformation describe-stack-resources --stack-name "${name}" \
      --query 'StackResources[?ResourceType==`AWS::EC2::InternetGateway`].PhysicalResourceId' --output text 2>/dev/null || true)"

    if [[ -n "${igw_id}" && "${igw_id}" != "None" ]]; then
      echo "Attempting to detach Internet Gateway ${igw_id} from VPC ${vpc_id}"

      # First, delete any routes using the IGW
      local route_table_id
      route_table_id="$(aws --region "${REGION}" cloudformation describe-stack-resources --stack-name "${name}" \
        --query 'StackResources[?ResourceType==`AWS::EC2::RouteTable`].PhysicalResourceId' --output text 2>/dev/null || true)"

      if [[ -n "${route_table_id}" && "${route_table_id}" != "None" ]]; then
        echo "Deleting route to IGW from route table ${route_table_id}"
        aws --region "${REGION}" ec2 delete-route --route-table-id "${route_table_id}" \
          --destination-cidr-block "0.0.0.0/0" 2>/dev/null || true
      fi

      # Now detach the IGW
      aws --region "${REGION}" ec2 detach-internet-gateway --internet-gateway-id "${igw_id}" \
        --vpc-id "${vpc_id}" 2>/dev/null || true
      sleep 5
    fi
  fi

  # Clean up any remaining ENIs in the VPC that might be blocking
  if [[ -n "${vpc_id}" && "${vpc_id}" != "None" ]]; then
    local enis
    enis="$(aws --region "${REGION}" ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=${vpc_id}" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)"

    for eni in ${enis}; do
      if [[ -n "${eni}" && "${eni}" != "None" ]]; then
        echo "Deleting orphaned ENI: ${eni}"
        aws --region "${REGION}" ec2 delete-network-interface --network-interface-id "${eni}" 2>/dev/null || true
      fi
    done
  fi
}

function delete_stack_and_wait() {
  local name="$1"
  local force_cleanup_attempts=0
  local max_force_cleanup_attempts=3

  aws --region "${REGION}" cloudformation delete-stack --stack-name "${name}" >/dev/null 2>&1 || true

  # Poll because waiters are brittle (and we want to branch on DELETE_FAILED).
  for _ in $(seq 1 180); do # up to ~30m
    local st
    st="$(stack_status "${name}")"
    if [[ -z "${st}" || "${st}" == "None" ]]; then
      echo "Stack ${name} successfully deleted"
      return 0
    fi

    if [[ "${st}" == "DELETE_FAILED" ]]; then
      echo "Stack deletion failed (DELETE_FAILED): ${name}"
      dump_stack_failure "${name}"

      if [[ "${force_cleanup_attempts}" -lt "${max_force_cleanup_attempts}" ]]; then
        force_cleanup_attempts=$((force_cleanup_attempts + 1))
        echo "Attempting force cleanup (attempt ${force_cleanup_attempts}/${max_force_cleanup_attempts})..."
        force_cleanup_stack_resources "${name}"
        sleep 10
        aws --region "${REGION}" cloudformation delete-stack --stack-name "${name}" >/dev/null 2>&1 || true
      else
        echo "Max force cleanup attempts reached, giving up on stack ${name}"
        return 1
      fi
    fi

    sleep 10
  done

  echo "Timed out waiting for stack deletion: ${name}"
  dump_stack_failure "${name}"
  return 1
}

function delete_stacks()
{
    local stack_list=$1
    local has_failures=0

    for stack_name in $(tac "${stack_list}"); do
        echo "Deleting stack ${stack_name} ..."

        if delete_stack_and_wait "${stack_name}"; then
            echo "Successfully deleted stack ${stack_name}"
        else
            echo "WARNING: Failed to delete stack ${stack_name}"
            has_failures=1
        fi
    done

    return ${has_failures}
}

echo "Deleting AWS CloudFormation stacks"

stack_list="${SHARED_DIR}/to_be_removed_cf_stack_list"
if [ -e "${stack_list}" ]; then
    echo "Deleting stacks:"
    cat "${stack_list}"
    if ! delete_stacks "${stack_list}"; then
        echo "WARNING: Some stacks failed to delete completely"
    fi
else
    echo "No stack list found at ${stack_list}, nothing to delete"
fi

exit 0
