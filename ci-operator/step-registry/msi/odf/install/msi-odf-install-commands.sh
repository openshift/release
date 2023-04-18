#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
AWS_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/.aws


OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
export OCM_TOKEN=${OCM_TOKEN}

export CLUS_DIR=${CLUSTER_PROFILE_DIR}

export MY_TEST="test_variable"
echo -e "test var : $MY_TEST"


KEY_ID=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
ACCESS_KEY=$(cat $AWS_SHARED_CREDENTIALS_FILE | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
export AWS_ACCESS_KEY_ID=$KEY_ID
export AWS_SECRET_ACCESS_KEY=$ACCESS_KEY


echo -e "env var injected: $TEST_ENV_VAR"

sleep 10800