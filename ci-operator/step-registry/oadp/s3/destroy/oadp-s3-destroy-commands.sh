#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set variables needed to login to AWS
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE=$CLUSTER_PROFILE_DIR/.aws
AWS_ACCESS_KEY_ID=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
AWS_SECRET_ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY

# Set BUCKET variable to a unique value
export BUCKET="${NAMESPACE}-${BUCKET_NAME}"

# Destroy S3 Bucket
/bin/bash /home/jenkins/oadp-qe-automation/backup-locations/aws-s3/destroy.sh $BUCKET
