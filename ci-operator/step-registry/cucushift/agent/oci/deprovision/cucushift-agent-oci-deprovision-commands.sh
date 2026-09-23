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

echo "Destroying Job"
SUCCESS=0

for ((i = 0; i < 2; i++)); do
    if oci resource-manager job create-destroy-job \
       --stack-id "${STACK_ID}" \
       --execution-plan-strategy=AUTO_APPROVED \
       --max-wait-seconds 2400 \
       --wait-for-state SUCCEEDED \
       --query 'data."lifecycle-state"'; then
        SUCCESS=1
        echo "$(date -u --rfc-3339=seconds) - Destroy job has completed successfully!!"
        break
    else
        echo "$(date -u --rfc-3339=seconds) - Failed to destroy job. Retrying..."
    fi
done
if [ "$SUCCESS" -ne 1 ]; then
  echo "Destroy job failed after 2 attempts!!!"
  exit 1
fi

echo "Deleting Stack"
oci resource-manager stack delete --stack-id "${STACK_ID}" --force
