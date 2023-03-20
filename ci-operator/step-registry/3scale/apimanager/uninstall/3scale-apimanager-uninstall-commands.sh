#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
AWS_ACCESS_KEY_ID=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
AWS_SECRET_ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)

# Set environment variables needed
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_REGION='us-east-2'
export DEPL_PROJECT_NAME='threescale'
export DEPL_BUCKET_NAME='3scale-apimanager-s3-bucket'

echo "Uninstalling APIManager"
deploy uninstall