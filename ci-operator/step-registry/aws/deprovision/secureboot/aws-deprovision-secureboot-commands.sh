#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

RESOURCES_FILE="${SHARED_DIR}/secureboot-resources.txt"

if [[ ! -f "${RESOURCES_FILE}" ]]; then
  echo "No Secure Boot resources to clean up"
  exit 0
fi

source "${RESOURCES_FILE}"

missing=()
[[ -z "${AMI_ID:-}" ]] && missing+=(AMI_ID)
[[ -z "${SNAPSHOT_ID:-}" ]] && missing+=(SNAPSHOT_ID)
[[ -z "${REGION:-}" ]] && missing+=(REGION)
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: ${RESOURCES_FILE} is missing required variable(s): ${missing[*]}"
  exit 1
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION="${REGION}"

ret=0

echo "Deregistering Secure Boot AMI: ${AMI_ID}"
if ! aws ec2 deregister-image --image-id "${AMI_ID}"; then
  echo "ERROR: Failed to deregister AMI ${AMI_ID}"
  ret=1
fi

echo "Deleting copied snapshot: ${SNAPSHOT_ID}"
if ! aws ec2 delete-snapshot --snapshot-id "${SNAPSHOT_ID}"; then
  echo "ERROR: Failed to delete snapshot ${SNAPSHOT_ID}"
  ret=1
fi

if [[ "${ret}" -eq 0 ]]; then
  echo "Secure Boot resource cleanup complete"
else
  echo "ERROR: Secure Boot resource cleanup finished with errors, resources may have leaked"
fi

exit ${ret}
