#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

SECRETS_DIR=/run/secrets/ci.openshift.io/cluster-profile
AWS_SECRET_ACCESS_KEY=$(cat $SECRETS_DIR/aws-secret-access-key)
AWS_ACCESS_KEY_ID=$(cat $SECRETS_DIR/aws-access-key-id)
CI_S3_BUCKET_NAME=$(cat $SECRETS_DIR/ci-s3-bucket-name)
CI_S3_BUCKET_REGION=$(cat $SECRETS_DIR/ci-s3-bucket-region)
CI_S3_BUCKET_ENDPOINT=$(cat $SECRETS_DIR/ci-s3-bucket-endpoint)
MODELS_S3_BUCKET_NAME=$(cat $SECRETS_DIR/models-s3-bucket-name)
MODELS_S3_BUCKET_REGION=$(cat $SECRETS_DIR/models-s3-bucket-region)
MODELS_S3_BUCKET_ENDPOINT=$(cat $SECRETS_DIR/models-s3-bucket-endpoint)


export AWS_SECRET_ACCESS_KEY
export AWS_ACCESS_KEY_ID
export CI_S3_BUCKET_NAME
export CI_S3_BUCKET_REGION
export CI_S3_BUCKET_ENDPOINT
export MODELS_S3_BUCKET_NAME
export MODELS_S3_BUCKET_REGION
export MODELS_S3_BUCKET_ENDPOINT


RUN_COMMAND="uv run pytest tests/model_serving/model_server \
            -s -p no:logging \
            --junit-xml=${ARTIFACT_DIR}/xunit_results.xml \
            --pytest-log-file=${ARTIFACT_DIR}/pytest-tests.log"


if [ -n "${TEST_MARKER}" ]; then
    RUN_COMMAND+=" -m ${TEST_MARKER} "
fi

if [ -n "${TEST_SELECTORS}" ]; then
    RUN_COMMAND+=" -k ${TEST_SELECTORS} "
fi

echo "$RUN_COMMAND"

${RUN_COMMAND}
