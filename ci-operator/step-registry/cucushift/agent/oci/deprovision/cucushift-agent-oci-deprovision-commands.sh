#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required to be able to SSH.
if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >>/etc/passwd
  else
    echo "/etc/passwd is not writeable, and user matching this uid is not found."
    exit 1
  fi
fi
curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/install.sh
chmod +x /tmp/install.sh
/tmp/install.sh --accept-all-defaults --exec-dir /tmp 2>/dev/null

source "${SHARED_DIR}"/platform-conf.sh
CONTENT=$(<"${CLUSTER_PROFILE_DIR}"/oci-privatekey)
export OCI_CLI_KEY_CONTENT=${CONTENT}

if [ -e "$(<"${SHARED_DIR}"/agent-image.txt)" ]; then
  echo "Deleting ISO from the bucket"
  OBJECT_NAME=$(<"${SHARED_DIR}"/agent-image.txt)
  /tmp/oci os object delete \
  --bucket-name "${BUCKET_NAME}" \
  --namespace-name "${NAMESPACE_NAME}" \
  --object-name "${OBJECT_NAME}" --force
fi

echo "Creating Destroy Job"
/tmp/oci resource-manager job create-destroy-job \
--stack-id "${STACK_ID}" \
--execution-plan-strategy=AUTO_APPROVED \
--max-wait-seconds 2400 \
--wait-for-state SUCCEEDED \
--query 'data."lifecycle-state"'

echo "Deleting Stack"
/tmp/oci resource-manager stack delete --stack-id "${STACK_ID}" --force
