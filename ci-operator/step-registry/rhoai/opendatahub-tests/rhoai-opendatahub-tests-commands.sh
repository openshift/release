#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose


if [ "${SET_AWS_ENV_VARS}" = "true" ]; then
  AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
  AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
  BUCKET_INFO="/tmp/secrets/ci"
  CI_S3_BUCKET_NAME="$(cat ${BUCKET_INFO}/CI_S3_BUCKET_NAME)"
  MODELS_S3_BUCKET_NAME="$(cat ${BUCKET_INFO}/MODELS_S3_BUCKET_NAME)"

  export AWS_SECRET_ACCESS_KEY
  export AWS_ACCESS_KEY_ID
  export CI_S3_BUCKET_NAME
  export CI_S3_BUCKET_REGION="us-east-1"
  export CI_S3_BUCKET_ENDPOINT="https://s3.us-east-1.amazonaws.com/"
  export MODELS_S3_BUCKET_NAME
  export MODELS_S3_BUCKET_REGION="us-east-2"
  export MODELS_S3_BUCKET_ENDPOINT="https://s3.us-east-2.amazonaws.com/"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

RUN_COMMAND="uv run pytest tests/model_serving/model_server \
            --tc=use_unprivileged_client:False \
            -s -o log_cli=true \
            --junit-xml=${ARTIFACT_DIR}/xunit_results.xml \
            --log-file=${ARTIFACT_DIR}/pytest-tests.log"

if [ "${SKIP_CLUSTER_SANITY_CHECK}" = "true" ]; then
  RUN_COMMAND+=" --cluster-sanity-skip-check "
fi

if [ "${SKIP_RHOAI_SANITY_CHECK}" = "true" ]; then
  RUN_COMMAND+=" --cluster-sanity-skip-rhoai-check "
fi

if [ -n "${TEST_MARKERS}" ]; then
    RUN_COMMAND+=" -m ${TEST_MARKERS} "
fi

if [ -n "${TEST_SELECTORS}" ]; then
    RUN_COMMAND+=" -k ${TEST_SELECTORS} "
fi

echo "$RUN_COMMAND"

${RUN_COMMAND}
