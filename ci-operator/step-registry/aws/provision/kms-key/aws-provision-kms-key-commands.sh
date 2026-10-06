#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION=${REGION:-$LEASED_RESOURCE}
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

# get user arn
USER_ARN=$(aws sts get-caller-identity --output json | jq -r .Arn)
KEY_POLICY=${ARTIFACT_DIR}/key_policy.json

cat > ${KEY_POLICY} << EOF
{
    "Id": "key-consolepolicy-3",
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "Enable IAM User Permissions",
            "Effect": "Allow",
            "Principal": {
                "AWS": "${USER_ARN/user*/root}"
            },
            "Action": "kms:*",
            "Resource": "*"
        },
        {
            "Sid": "Allow use of the key",
            "Effect": "Allow",
            "Principal": {
                "AWS": "${USER_ARN}"
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
                "AWS": "${USER_ARN}"
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


function create_kms_key()
{
    local id_output=$1
    local arn_output=$2

    local key_arn key_id output ts

    ts=$(date +%m%d%H%M%S)
    key_alias="alias/prowci-${CLUSTER_NAME}-${ts}-${RANDOM}"
    output=$(mktemp)

    echo "Creating KMS key: $key_alias"
    aws --region $REGION kms create-key --description "Prow CI $key_alias" --output json \
        --policy "$(cat $KEY_POLICY | jq -c)" > "${output}" || return 1
    
    key_arn=$(cat "${output}" | jq -r '.KeyMetadata.Arn')
    key_id=$(cat "${output}" | jq -r '.KeyMetadata.KeyId')

    if [[ "${key_arn}" == "" ]] || [[ "${key_arn}" == "null" ]] || [[ "${key_id}" == "" ]] || [[ "${key_id}" == "null" ]]; then
        echo "Failed to create KMS key."
        return 1
    fi

    echo $key_arn > "${arn_output}"
    echo $key_id > "${id_output}"

    echo "Created key $key_id"
    aws --region $REGION kms create-alias --alias-name "${key_alias}" --target-key-id "${key_id}"
    echo "Created key alias $key_alias"
}

if [[ "${ENABLE_AWS_KMS_KEY_DEFAULT_MACHINE}" == "yes" ]]; then
    create_kms_key "${SHARED_DIR}/aws_kms_key_id" "${SHARED_DIR}/aws_kms_key_arn"
fi

if [[ "${ENABLE_AWS_KMS_KEY_CONTROL_PLANE}" == "yes" ]]; then
    create_kms_key "${SHARED_DIR}/aws_kms_key_id_control_plane" "${SHARED_DIR}/aws_kms_key_arn_control_plane"
fi

if [[ "${ENABLE_AWS_KMS_KEY_COMPUTE}" == "yes" ]]; then
    create_kms_key "${SHARED_DIR}/aws_kms_key_id_compute" "${SHARED_DIR}/aws_kms_key_arn_compute"
fi
