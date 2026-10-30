#!/bin/bash
set -o nounset
set -o pipefail
set -x

export AWS_DEFAULT_REGION="${AWS_REGION}"
AWS_CREDS="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_ACCESS_KEY_ID=$(grep aws_access_key_id "${AWS_CREDS}" | awk '{print $3}')
export AWS_SECRET_ACCESS_KEY=$(grep aws_secret_access_key "${AWS_CREDS}" | awk '{print $3}')

if [ -f "${SHARED_DIR}/ext_instance_id" ]; then
  EXT_INSTANCE_ID=$(cat "${SHARED_DIR}/ext_instance_id")
  echo "Terminating instance ${EXT_INSTANCE_ID}"
  aws ec2 terminate-instances --instance-ids "${EXT_INSTANCE_ID}" || true
fi

if [ -f "${SHARED_DIR}/ext_key_name" ]; then
  KEY_NAME=$(cat "${SHARED_DIR}/ext_key_name")
  echo "Deleting key pair ${KEY_NAME}"
  aws ec2 delete-key-pair --key-name "${KEY_NAME}" || true
fi

echo "Teardown complete"
