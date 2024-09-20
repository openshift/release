#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ ${USE_PUBLIC_IPV4_POOL_INGRESS-} != "yes" ]]; then
  exit 0
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"


if test ! -f "${SHARED_DIR}/eip_allocation_ids"
then
  echo "No Elastic IP allocations found at eip_allocation_ids."
  exit 0
fi

for eip_allocation_id in $(tr ',' ' ' < "${SHARED_DIR}/eip_allocation_ids")
do
  echo "Releasing Elastic IP allocation ${eip_allocation_id}"
  aws --region "${REGION}" ec2 release-address --allocation-id "${eip_allocation_id}"
done
