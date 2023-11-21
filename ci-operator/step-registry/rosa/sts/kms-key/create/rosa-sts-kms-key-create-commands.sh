#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}

# get user arn
# arn:aws:iam::301721915996:user/qe-jenkins
user_arn=$(aws sts get-caller-identity --output json | jq -r .Arn)
KMS_KEY_POLICY=$(echo -e '
{
    "Version": "2012-10-17",
    "Id": "key-rosa-policy-1",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {
                "AWS": "'${user_arn/user*/root}'"
            },
            "Action": "kms:*",
            "Resource": "*"
        },
        {
            "Sid": "Allow ROSA use of the key",
            "Effect": "Allow",
            "Principal": {
                "AWS": []
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
                "AWS": []
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
}')
echo "KMS Key Policy Template:"
echo $KMS_KEY_POLICY | jq

ACCOUNT_ROLES_ARNS_FILE="${SHARED_DIR}/account-roles-arns"
for i in $(cat "$ACCOUNT_ROLES_ARNS_FILE"); do
  KMS_KEY_POLICY=$(echo "${KMS_KEY_POLICY}" | jq '.Statement[1].Principal.AWS +=["'$i'"]')
  KMS_KEY_POLICY=$(echo "${KMS_KEY_POLICY}" | jq '.Statement[2].Principal.AWS +=["'$i'"]')
done

OPERATOR_ROLES_ARNS_FILE="${SHARED_DIR}/operator-roles-arns"
if [[ -e "${OPERATOR_ROLES_ARNS_FILE}" ]]; then
  for i in $(cat "$OPERATOR_ROLES_ARNS_FILE"); do
     KMS_KEY_POLICY=$(echo "${KMS_KEY_POLICY}" | jq '.Statement[1].Principal.AWS +=["'${i}'"]')
     KMS_KEY_POLICY=$(echo "${KMS_KEY_POLICY}" | jq '.Statement[2].Principal.AWS +=["'${i}'"]')
  done
fi

ts=$(date +%m%d%H%M%S)
alias_name="${NAMESPACE}-${ts}"
echo "Creating KMS key: $alias_name"
key_output=${ARTIFACT_DIR}/key_output.json

aws --region $REGION kms create-key --description "Prow CI $alias_name" \
  --output json \
  --policy "$(echo $KMS_KEY_POLICY | jq -c)" > "${key_output}" || exit 1

cat $key_output
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
