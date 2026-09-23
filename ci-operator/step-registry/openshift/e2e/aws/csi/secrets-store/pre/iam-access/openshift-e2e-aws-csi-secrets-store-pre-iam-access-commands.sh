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
POLICY_NAME="SSCSI-IAM-POLICY-${UNIQUE_HASH}"
POLICY_FILE=${ARTIFACT_DIR}/sscsi_aws_iam_policy.json

echo "Starting IAM permission setup for user: '$AWS_USER_NAME'"
cat > "$POLICY_FILE" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowIAMManagementForCSITests",
            "Effect": "Allow",
            "Action": [
                "iam:CreatePolicy",
                "iam:AttachUserPolicy",
                "iam:DetachUserPolicy",
                "iam:DeletePolicy",
                "iam:CreateRole",
                "iam:AttachRolePolicy",
                "iam:DetachRolePolicy",
                "iam:DeleteRole"
            ],
            "Resource": "*"
        },
        {
            "Sid": "AllowSecretAndParameterManagementForCSITests",
            "Effect": "Allow",
            "Action": [
                "secretsmanager:CreateSecret",
                "secretsmanager:PutSecretValue",
                "secretsmanager:DeleteSecret",
                "ssm:PutParameter",
                "ssm:DeleteParameter"
            ],
            "Resource": "*"
        }
    ]
}
EOF
echo "Policy document created successfully."

echo "Fetching AWS Account ID"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
echo "Constructed Policy ARN: $POLICY_ARN"

echo "Checking if policy '$POLICY_NAME' exists"
if aws iam get-policy --policy-arn "$POLICY_ARN" > /dev/null 2>&1; then
    echo "Policy '$POLICY_NAME' already exists. Skipping creation."
else
    echo "Policy does not exist. Creating policy '$POLICY_NAME'"
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document "file://${POLICY_FILE}"
    echo "Policy created successfully."
fi

echo "Attaching policy '$POLICY_NAME' to user '$AWS_USER_NAME'"
aws iam attach-user-policy \
    --user-name "$AWS_USER_NAME" \
    --policy-arn "$POLICY_ARN"
echo "Policy attached successfully."

echo "Verifying policy attachment"
if aws iam list-attached-user-policies --user-name "$AWS_USER_NAME" | grep -q "$POLICY_ARN"; then
    echo "Verification successful: Policy '$POLICY_NAME' is correctly attached to user '$AWS_USER_NAME'."
else
    echo "Verification failed: Could not confirm policy attachment."
    exit 1
fi

echo "Saving policy arn: ${POLICY_ARN}"
echo "${POLICY_ARN}" > ${SHARED_DIR}/sscsi_aws_iam_policy_arn

echo "All steps completed successfully!"
