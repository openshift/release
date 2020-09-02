#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if test ! -f "${SHARED_DIR}/proxyregion"
then
  echo "No proxyregion, so unknown AWS region, so unable to tear down."
  exit 0
fi

REGION="$(cat "${SHARED_DIR}/proxyregion")"
PROXY_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
STACK_NAME="${PROXY_NAME}-proxy"

# cleaning up after ourselves
if aws --region "${REGION}" s3api head-bucket --bucket "${PROXY_NAME}" > /dev/null 2>&1
then
  aws --region "${REGION}" s3 rb "s3://${PROXY_NAME}" --force
fi

aws --region "${REGION}" cloudformation delete-stack --stack-name "${STACK_NAME}" &
wait "$!"

aws --region "${REGION}" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" &
wait "$!"
