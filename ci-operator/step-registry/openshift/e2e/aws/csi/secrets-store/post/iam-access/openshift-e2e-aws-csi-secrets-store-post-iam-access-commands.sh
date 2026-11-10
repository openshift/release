#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Set variables needed to login to AWS
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE=$CLUSTER_PROFILE_DIR/.aws

KEY_ID=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
export AWS_ACCESS_KEY_ID=$KEY_ID
export AWS_SECRET_ACCESS_KEY=$ACCESS_KEY

if [[ ${AWS_ACCESS_KEY_ID} == "" ]] || [[ ${AWS_SECRET_ACCESS_KEY} == "" ]]; then
  echo "Did not find AWS credential, exit now"
  exit 1
fi

REGION=${REGION:-$LEASED_RESOURCE}

# get user arn
AWS_USER_NAME=$(aws sts get-caller-identity --query 'Arn' --output text | cut -d'/' -f2)
# The file where the policy ARN is stored.
POLICY_ARN_FILE="${SHARED_DIR}/sscsi_aws_iam_policy_arn"

if [ ! -f "$POLICY_ARN_FILE" ]; then
    echo "Policy ARN file not found at '$POLICY_ARN_FILE'. Skipping cleanup."
    exit 0
fi

POLICY_ARN=$(cat "$POLICY_ARN_FILE")
if [ -z "$POLICY_ARN" ]; then
    echo "Policy ARN file is empty. Skipping cleanup."
    exit 0
fi

echo "Successfully read Policy ARN: $POLICY_ARN"
echo "Detaching policy from user '$AWS_USER_NAME'"
aws iam detach-user-policy --user-name "$AWS_USER_NAME" --policy-arn "$POLICY_ARN" || true
echo "Policy detachment step complete."

echo "Deleting policy '$POLICY_ARN'"
aws iam delete-policy --policy-arn "$POLICY_ARN" || true
echo "Policy deletion step complete."

echo "Cleanup finished."
