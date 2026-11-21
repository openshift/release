#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Zero-egress VPC cleanup (ROSAENG-66391): delete the VPC endpoints and their
# security group created by rosa-e2e-hcp-zero-egress-vpc-prepare. VPC endpoints
# block VPC deletion, so this must run before rosa-e2e-cleanup-vpc /
# aws-deprovision-stacks tear down the VPC stack.

CLOUD_PROVIDER_REGION="${LEASED_RESOURCE}"

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
else
  echo "No zero-egress VPC endpoints to delete"
fi

if [[ -s "${SHARED_DIR}/zero_egress_endpoint_sg_id" ]]; then
  ENDPOINT_SG_ID=$(cat "${SHARED_DIR}/zero_egress_endpoint_sg_id")
  echo "Deleting endpoint security group ${ENDPOINT_SG_ID}"
  aws ec2 delete-security-group --group-id "${ENDPOINT_SG_ID}" || true
fi

echo "Zero-egress VPC cleanup done"
