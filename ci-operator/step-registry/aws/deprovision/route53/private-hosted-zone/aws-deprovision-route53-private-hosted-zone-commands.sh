#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
HOSTED_ZONE_ID="${SHARED_DIR}/hosted_zone_id"

if [ ! -f "${HOSTED_ZONE_ID}" ]; then
  echo "File ${HOSTED_ZONE_ID} does not exist."
  exit 1
fi

echo "Deleting AWS route53 hosted zone"
HOSTED_ZONE="$(aws --region "${REGION}" route53 delete-hosted-zone --id  "$(cat "${HOSTED_ZONE_ID}")")"
CHANGE_ID="$(echo "${HOSTED_ZONE}" | jq -r '.ChangeInfo.Id' | awk -F / '{printf $3}')"

aws --region "${REGION}" route53 wait resource-record-sets-changed --id "${CHANGE_ID}" &
wait "$!"
echo "AWS route53 hosted zone $(cat "${HOSTED_ZONE_ID}") successfully deleted."
