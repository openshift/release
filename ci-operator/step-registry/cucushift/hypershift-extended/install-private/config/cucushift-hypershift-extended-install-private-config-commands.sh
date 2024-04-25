#!/bin/bash

set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

BUCKET_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "create bucket name: $BUCKET_NAME ,region $HYPERSHIFT_AWS_REGION"
if [ "$HYPERSHIFT_AWS_REGION" == "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" \
        --region us-east-1
else
    aws s3api create-bucket --bucket "$BUCKET_NAME" \
        --create-bucket-configuration LocationConstraint="$HYPERSHIFT_AWS_REGION" \
        --region "$HYPERSHIFT_AWS_REGION"
fi
aws s3api delete-public-access-block --bucket "$BUCKET_NAME"
export BUCKET_NAME=$BUCKET_NAME
echo '{
    "Version": "2012-10-17",
    "Statement": [
        {
        "Effect": "Allow",
        "Principal": "*",
        "Action": "s3:GetObject",
        "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
        }
    ]
}' | envsubst > /tmp/bucketpolicy.json
aws s3api put-bucket-policy --bucket "$BUCKET_NAME" --policy file:///tmp/bucketpolicy.json

#echo "Create a hypershift-operator IAM user in the management account"
#echo '{
#    "Version": "2012-10-17",
#    "Statement": [
#        {
#            "Effect": "Allow",
#            "Action": [
#                "ec2:CreateVpcEndpointServiceConfiguration",
#                "ec2:DescribeVpcEndpointServiceConfigurations",
#                "ec2:DeleteVpcEndpointServiceConfigurations",
#                "ec2:DescribeVpcEndpointServicePermissions",
#                "ec2:ModifyVpcEndpointServicePermissions",
#                "ec2:CreateTags",
#                "elasticloadbalancing:DescribeLoadBalancers"
#            ],
#            "Resource": "*"
#        }
#    ]
#}' > /tmp/policy.json
#
#echo "create policy"
#policy_arn=$(aws iam list-policies --query 'Policies[?PolicyName==`hypershift-operator-policy`].Arn' | awk -F '\"' '{print $2}')
#if [ -z "$policy_arn" ] ; then
#    aws iam create-policy --policy-name=hypershift-operator-policy --policy-document=file:///tmp/policy.json
#    [ $? -ne 0 ] && exit 1
#    policy_arn=$(aws iam list-policies --query 'Policies[?PolicyName==`hypershift-operator-policy`].Arn' | awk -F '\"' '{print $2}')
#    [ -z "$policy_arn" ] && exit 1
#else
#    echo "using existing policy hypershift-operator-policy with arn $policy_arn"
#fi
#
#echo "create user hypershift-operator"
#user=$(aws iam get-user --user-name=hypershift-operator 2>/dev/null || true)
#if [ -z "$user" ] ; then
#    aws iam create-user --user-name=hypershift-operator
#    [ $? -ne 0 ] && exit 1
#else
#    echo "using existing user $user"
#fi
#
#echo "attach-user-policy"
#user_policy=$(aws iam get-user-policy --user-name hypershift-operator --policy-name hypershift-operator-policy 2>&1 || true)
#user_policy_err=$(echo "$user_policy"| grep -c NoSuchEntity)
#if [ $user_policy_err -gt 0 ] ; then
#    aws iam attach-user-policy --user-name hypershift-operator --policy-arn $policy_arn
#    [ $? -ne 0 ] && exit 1
#    echo "attach user-policy successfully"
#else
#    echo "using existing user-policy $user_policy"
#fi
#
#access_id=$(aws iam list-access-keys --user-name=hypershift-operator |  jq -r '.AccessKeyMetadata[0].AccessKeyId')
## if found existing accesskeyid, delete it and recreate one
#if [ "${access_id}" != "null" ] ; then
#    aws iam delete-access-key --user-name=hypershift-operator --access-key-id=${access_id}
#    [ $? -ne 0 ] && exit 1
#fi
#
#access_key=$(aws iam create-access-key --user-name=hypershift-operator)
#accessKeyID=$(echo "$access_key" | jq -r '.AccessKey.AccessKeyId')
#secureKey=$(echo "$access_key" | jq -r '.AccessKey.SecretAccessKey')
#echo -e "[default]\naws_access_key_id=$accessKeyID\naws_secret_access_key=$secureKey" > $SHARED_DIR/.awsprivatecred
#echo "config awsprivatecred successfully"
