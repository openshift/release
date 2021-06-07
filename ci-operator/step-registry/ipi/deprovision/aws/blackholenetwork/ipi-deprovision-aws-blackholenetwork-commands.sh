#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if test ! -f "${SHARED_DIR}/blackholenetworkstackname"
then
  echo "No blackholenetworkstackname, so unknown stack name, so unable to tear down."
  exit 0
fi

REGION="${LEASED_RESOURCE}"
STACK_NAME="$(cat "${SHARED_DIR}/blackholenetworkstackname")"

# cleaning up after ourselves
aws --region "${REGION}" cloudformation delete-stack --stack-name "${STACK_NAME}" &
wait "$!"

aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" &
wait "$!"

echo "${STACK_NAME} stack delete complete"
