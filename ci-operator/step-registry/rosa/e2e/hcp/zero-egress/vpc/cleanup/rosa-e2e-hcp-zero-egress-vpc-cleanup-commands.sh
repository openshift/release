#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Zero-egress VPC cleanup (ROSAENG-66391): delete the VPC endpoints and their
# security group created by rosa-e2e-hcp-zero-egress-vpc-prepare. VPC endpoints
# block VPC deletion, so this must run before rosa-e2e-cleanup-vpc /
# aws-deprovision-stacks tear down the VPC stack.

# Match the producer's region selection (aws-provision-vpc-shared): REGION
# wins when set, LEASED_RESOURCE (the lease region) is the fallback.
CLOUD_PROVIDER_REGION="${REGION:-${LEASED_RESOURCE}}"

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

if [[ -s "${SHARED_DIR}/zero_egress_endpoint_ids" ]]; then
  mapfile -t ENDPOINT_IDS < <(grep -v '^$' "${SHARED_DIR}/zero_egress_endpoint_ids")
  for endpoint_id in "${ENDPOINT_IDS[@]}"; do
    if [[ -n "${endpoint_id}" ]]; then
      echo "Deleting VPC endpoint ${endpoint_id}"
      aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${endpoint_id}" || true
    fi
  done
  # Endpoint deletion is asynchronous: interface endpoints leave network
  # interfaces that hold the endpoint security group. Wait for the endpoints
  # to disappear before deleting the group — a DependencyViolation there
  # would strand the group and block VPC deletion at stack teardown. Only a
  # confirmed absent endpoint counts as gone (empty lookup result, or a
  # lookup error naming it not-found); transient lookup failures such as
  # RequestLimitExceeded keep polling so the security-group retry window is
  # not started while deletion is still in flight. The step fails if any
  # recorded endpoint survives the poll so the leftover is visible.
  all_gone=true
  for endpoint_id in "${ENDPOINT_IDS[@]}"; do
    [[ -n "${endpoint_id}" ]] || continue
    gone=false
    for _ in $(seq 1 60); do
      if output=$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "${endpoint_id}" \
        --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>&1); then
        if [[ "${output}" == "None" ]]; then
          gone=true
          break
        fi
      elif grep -qiE 'not ?found|does not exist' <<<"${output}"; then
        gone=true
        break
      else
        echo "WARNING: endpoint ${endpoint_id} lookup failed: ${output}"
      fi
      sleep 10
    done
    if [[ "${gone}" != true ]]; then
      echo "ERROR: endpoint ${endpoint_id} still present after 10 minutes"
      all_gone=false
    fi
  done
  if [[ "${all_gone}" != true ]]; then
    exit 1
  fi
else
  echo "No zero-egress VPC endpoints to delete"
fi

if [[ -s "${SHARED_DIR}/zero_egress_endpoint_sg_id" ]]; then
  ENDPOINT_SG_ID=$(cat "${SHARED_DIR}/zero_egress_endpoint_sg_id")
  echo "Deleting endpoint security group ${ENDPOINT_SG_ID}"
  # Retry to absorb residual ENI release after endpoint deletion; fail the
  # step if the group survives so the leftover is visible instead of
  # silently blocking VPC deletion later.
  deleted=false
  for _ in $(seq 1 12); do
    if aws ec2 delete-security-group --group-id "${ENDPOINT_SG_ID}" 2>/dev/null; then
      deleted=true
      break
    fi
    sleep 10
  done
  if [[ "${deleted}" == false ]]; then
    echo "ERROR: endpoint security group ${ENDPOINT_SG_ID} could not be deleted (still in use?)"
    exit 1
  fi
fi

echo "Zero-egress VPC cleanup done"
