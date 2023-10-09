#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

# If the IAM role and policy exist, do deletion.
iam_role_name=$(head -n 1 ${SHARED_DIR}/iam_role_name || true)
iam_policy_arn=$(head -n 1 ${SHARED_DIR}/iam_policy_arn || true)
if [[ ! -z "$iam_policy_arn" ]]; then
  if [[ ! -z "$iam_role_name" ]]; then
    aws --region $REGION iam detach-role-policy --policy-arn ${iam_policy_arn} --role-name ${iam_role_name}
  fi

  echo "Delete IAM policy $iam_policy_arn ..."
  aws --region $REGION iam delete-policy --policy-arn ${iam_policy_arn}
fi

if [[ ! -z "$iam_role_name" ]]; then
  echo "Delete IAM role $iam_role_name ..."
  aws --region $REGION iam delete-role --role-name ${iam_role_name}
fi

echo "Finish audit log deletion."
