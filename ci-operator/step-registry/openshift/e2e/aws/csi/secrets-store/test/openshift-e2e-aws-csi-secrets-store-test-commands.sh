#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Set variables needed to login to AWS
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_CONFIG_FILE=$CLUSTER_PROFILE_DIR/.aws

KEY_ID=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
export AWS_ACCESS_KEY_ID=$KEY_ID
export AWS_SECRET_ACCESS_KEY=$ACCESS_KEY

if [[ ${AWS_ACCESS_KEY_ID} == "" ]] || [[ ${AWS_SECRET_ACCESS_KEY} == "" ]]; then
    echo "Did not find AWS credential, exit now"
    exit 1
fi

aws_region=${REGION:-$LEASED_RESOURCE}
export REGION=$aws_region

# Run aws end-to-end tests
make e2e-aws
