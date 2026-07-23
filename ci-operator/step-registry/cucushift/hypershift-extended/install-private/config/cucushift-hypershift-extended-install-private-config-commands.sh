#!/bin/bash

set -o nounset
set -o pipefail
set -x

if [[ "${CLUSTER_TYPE,,}" != *aws* ]]; then
    echo "Running on platform ${CLUSTER_TYPE}, skipping this step"
    exit 0
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}

BUCKET_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "create bucket name: $BUCKET_NAME, region $REGION"
if [ "$REGION" == "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET_NAME" \
        --region us-east-1
else
    aws s3api create-bucket --bucket "$BUCKET_NAME" \
        --create-bucket-configuration LocationConstraint="$REGION" \
        --region "$REGION"
fi
aws s3api delete-public-access-block --bucket "$BUCKET_NAME"
export BUCKET_NAME=$BUCKET_NAME
# shellcheck disable=SC2016
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
