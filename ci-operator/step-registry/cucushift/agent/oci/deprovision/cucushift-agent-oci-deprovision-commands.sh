#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

source "${SHARED_DIR}"/platform-conf.sh
CONTENT=$(<"${CLUSTER_PROFILE_DIR}"/oci-privatekey)
export OCI_CLI_KEY_CONTENT=${CONTENT}

if [ -e "$(<"${SHARED_DIR}"/agent-image.txt)" ]; then
  echo "Deleting ISO from the bucket"
  OBJECT_NAME=$(<"${SHARED_DIR}"/agent-image.txt)
  oci os object delete \
  --bucket-name "${BUCKET_NAME}" \
  --namespace-name "${NAMESPACE_NAME}" \
  --object-name "${OBJECT_NAME}" --force
fi

echo "Creating Destroy Job"
oci resource-manager job create-destroy-job \
--stack-id "${STACK_ID}" \
--execution-plan-strategy=AUTO_APPROVED \
--max-wait-seconds 2400 \
--wait-for-state SUCCEEDED \
--query 'data."lifecycle-state"'

echo "Deleting Stack"
oci resource-manager stack delete --stack-id "${STACK_ID}" --force
