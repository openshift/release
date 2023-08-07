#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

# get user arn
# arn:aws:iam::301721915996:user/qe-jenkins
user_arn=$(aws sts get-caller-identity --output json | jq -r .Arn)
key_policy=${ARTIFACT_DIR}/key_policy.json

cat > ${key_policy} << EOF
{
    "Id": "key-consolepolicy-3",
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {
                "AWS": "${user_arn/user*/root}"
            },
            "Action": "kms:*",
            "Resource": "*"
        },
        {
            "Sid": "Allow use of the key",
            "Effect": "Allow",
            "Principal": {
                "AWS": "${user_arn}"
            },
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:ReEncrypt*",
                "kms:GenerateDataKey*",
                "kms:DescribeKey"
            ],
            "Resource": "*"
        },
        {
            "Sid": "Allow attachment of persistent resources",
            "Effect": "Allow",
            "Principal": {
                "AWS": "${user_arn}"
            },
            "Action": [
                "kms:CreateGrant",
                "kms:ListGrants",
                "kms:RevokeGrant"
            ],
            "Resource": "*",
            "Condition": {
                "Bool": {
                    "kms:GrantIsForAWSResource": "true"
                }
            }
        }
    ]
}
EOF


ts=$(date +%m%d%H%M%S)
alias_name="${CLUSTER_NAME}-${ts}"
echo "Creating KMS key: $alias_name"
echo "Policy:"
cat $key_policy

key_output=${ARTIFACT_DIR}/key_output.json

aws --region $REGION kms create-key --description "Prow CI $alias_name" \
  --output json \
  --policy "$(cat $key_policy | jq -c)" > "${key_output}" || exit 1

key_arn=$(cat "${key_output}" | jq -r '.KeyMetadata.Arn')
key_id=$(cat "${key_output}" | jq -r '.KeyMetadata.KeyId')

if [[ "${key_arn}" == "" ]] || [[ "${key_arn}" == "null" ]] || [[ "${key_id}" == "" ]] || [[ "${key_id}" == "null" ]]; then
  echo "Failed to create KMS key."
  exit 1
fi

echo "Created key $key_arn"

echo $key_arn > ${SHARED_DIR}/aws_kms_key_arn
echo $key_id > ${SHARED_DIR}/aws_kms_key_id

key_alias="alias/prowci-${alias_name}"
echo $key_alias > ${SHARED_DIR}/aws_kms_key_alias

aws --region $REGION kms create-alias --alias-name "${key_alias}" --target-key-id "${key_id}"
echo "Created key alias $key_alias"
