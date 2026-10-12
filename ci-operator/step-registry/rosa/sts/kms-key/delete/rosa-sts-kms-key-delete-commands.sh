#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

AWS_ACCOUNT_ID=$(aws sts get-caller-identity | jq -r '.Arn' | awk -F ":" '{print $5}')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

# If the kms key exists, do deletion.
pending_days=7
KMS_KEY_ID_FILE="${SHARED_DIR}/aws_kms_key_id"
if [[ -e "${KMS_KEY_ID_FILE}" ]]; then
  kms_key_id=$(head -n 1 ${KMS_KEY_ID_FILE})
  if [[ "${kms_key_id}" == "" ]]; then
    echo "ERROR: KMS key is empty."
    exit 1
  fi

  echo "KMS key $kms_key_id will be delete after $pending_days days."
  aws --region $REGION kms schedule-key-deletion \
    --key-id "${kms_key_id}" \
    --pending-window-in-days $pending_days \
    | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"
else
  echo "No kms key created in the pre step"
fi
echo "Finish kms key deletion."
