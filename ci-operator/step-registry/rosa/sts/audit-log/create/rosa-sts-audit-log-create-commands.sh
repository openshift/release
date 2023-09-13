#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${REGION:-$LEASED_RESOURCE}
subfix=$(date +%m%d%H%M%S)

# Create IAM policy
iam_policy_payload="${ARTIFACT_DIR}/iam-policy.json"
cat > ${iam_policy_payload} << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:PutLogEvents",
        "logs:CreateLogGroup",
        "logs:PutRetentionPolicy",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Effect": "Allow",
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
EOF
iam_policy_name="${NAMESPACE}-${subfix}"
iam_policy_output=${ARTIFACT_DIR}/iam_policy_output.json
aws --region $REGION iam create-policy --description "Prow CI rosa" \
  --output json \
  --policy-name $iam_policy_name \
  --policy-document file://${iam_policy_payload} > "${iam_policy_output}" || exit 1

echo "Create IAM policy $iam_policy_name successfully:"
cat $iam_policy_output
iam_policy_arn=$(cat "${iam_policy_output}" | jq -r '.Policy.Arn')
echo $iam_policy_arn > ${SHARED_DIR}/iam_policy_arn

# Create IAM role
user_arn=$(aws sts get-caller-identity --output json | jq -r .Arn)
oidc_config_url=$(cat "${SHARED_DIR}/oidc-config" | jq -r '.issuer_url' | sed -E 's|^https://(.*)|\1|')
trust_relationship_payload="${ARTIFACT_DIR}/trust-relationship.json"
cat > ${trust_relationship_payload} << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${user_arn/user*/oidc-provider}/${oidc_config_url}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_config_url}:sub": "system:serviceaccount:openshift-config-managed:cloudwatch-audit-exporter"
        }
      }
    }
  ]
}
EOF
iam_role_name="${NAMESPACE}-${subfix}"
iam_role_output=${ARTIFACT_DIR}/iam_role_output.json
aws --region $REGION iam create-role --description "Prow CI rosa" \
  --output json \
  --role-name $iam_role_name \
  --assume-role-policy-document file://${trust_relationship_payload} > "${iam_role_output}" || exit 1

echo "Create IAM policy $iam_role_name successfully:"
cat $iam_role_output
iam_role_arn=$(cat "${iam_role_output}" | jq -r '.Role.Arn')
echo $iam_role_name > ${SHARED_DIR}/iam_role_name
echo $iam_role_arn > ${SHARED_DIR}/iam_role_arn

# Attach role and policy
aws iam attach-role-policy --policy-arn ${iam_policy_arn} --role-name ${iam_role_name}
echo "Successfully create audit log."