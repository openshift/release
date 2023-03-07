#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE=$CLUSTER_PROFILE_DIR/.aws

INTEROP_AWS_ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
INTEROP_AWS_SECRET_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)

echo "Create bucket $BUCKET_NAME"
aws s3api create-bucket --bucket $BUCKET_NAME --region us-east-2 --create-bucket-configuration LocationConstraint=us-east-2

echo "Bucket created"

echo "Create-user"
aws iam create-user --user-name $BUCKET_NAME || true
# TODO: make it specific to single cluster EC2 instances
# XXX=$(aws ec2 describe-instances --filters Name=tag:Name,Values=cam-tgt-32920* --query "Reservations[].Instances[].InstanceId" --output text)
# echo -e "Resource [ \n$(for i in $XXX; do echo "\tarn:aws:ec2:::instance/$i",; done) \n ]"


cat > velero-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeVolumes",
                "ec2:DescribeSnapshots",
                "ec2:CreateTags",
                "ec2:CreateVolume",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:PutObject",
                "s3:AbortMultipartUpload",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation",
                "s3:ListBucketMultipartUploads"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}"
            ]
        }
    ]
}
EOF

echo "iam put-user-policy"

aws iam put-user-policy \
  --user-name $BUCKET_NAME \
  --policy-name $BUCKET_NAME \
  --policy-document file://velero-policy.json \
  || true
rm velero-policy.json

echo "create an access key for the user"

for key_id in $(aws iam list-access-keys --user-name $BUCKET_NAME | jq -r .AccessKeyMetadata[].AccessKeyId); do aws \
iam delete-access-key --access-key-id $key_id --user-name $BUCKET_NAME; done
CREDENTIALS=$(aws iam create-access-key --user-name $BUCKET_NAME)
PROFILE=default

echo "Create velero-specific credentials file in local dir"

CREDS_FILE="credentials"

cat > ${CREDS_FILE} << __EOF__
[${PROFILE}]
aws_access_key_id=$(echo $CREDENTIALS | jq -r .AccessKey.AccessKeyId)
aws_secret_access_key=$(echo $CREDENTIALS | jq -r .AccessKey.SecretAccessKey)
__EOF__

echo "Complete"