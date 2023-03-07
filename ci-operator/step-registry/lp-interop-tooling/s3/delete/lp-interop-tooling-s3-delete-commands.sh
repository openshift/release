#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE=$CLUSTER_PROFILE_DIR/.aws

INTEROP_AWS_ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
INTEROP_AWS_SECRET_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)

echo "Delete bucket named: oadptest"
aws s3api delete-bucket --bucket $BUCKET_NAME

echo "Bucket destroyed"