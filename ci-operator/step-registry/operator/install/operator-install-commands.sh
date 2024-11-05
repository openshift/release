#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

export KUBECONFIG=${SHARED_DIR}/kubeconfig
operator_configs=$(env | grep -E '^OPERATOR[0-9]+_CONFIG' | sort --version-sort)
RUN_COMMAND="poetry run python ocp_addons_operators_cli/cli.py --action install --kubeconfig ${KUBECONFIG} "
OPERATORS_CMD=""

extract_operator_config() {
    echo "$1" | sed -E 's/^OPERATOR[0-9]+_CONFIG=//'
}

for operator_value in $operator_configs; do
    operator_value=$(extract_operator_config "$operator_value")
    if  [ "${operator_value}" ]; then
      OPERATORS_CMD+=" --operator ${operator_value} "
    fi
done

RUN_COMMAND="${RUN_COMMAND} ${OPERATORS_CMD}"

if [ "${ADDONS_OPERATORS_RUN_IN_PARALLEL}" = "true" ]; then
    RUN_COMMAND+=" --parallel"
fi

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

if [ "${INSTALL_FROM_IIB}" = "true" ]; then
  if [ -z "$S3_BUCKET_OPERATORS_LATEST_IIB_PATH" ]; then
    echo "S3_BUCKET_OPERATORS_LATEST_IIB_PATH is mandatory for iib installation"
    exit 1
  fi

  if [ -z "$AWS_REGION" ]; then
    echo "AWS_REGION is mandatory for iib installation"
    exit 1
  fi

  AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
  AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
  BREW_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/brew-token")

  export BREW_TOKEN=${BREW_TOKEN}
  export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
  export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}

  RUN_COMMAND+=" --s3-bucket-operators-latest-iib-path ${S3_BUCKET_OPERATORS_LATEST_IIB_PATH} --aws-region ${AWS_REGION} "

fi

if [ "${COLLECT_MUST_GATHER}" = "true" ]; then
  RUN_COMMAND+=" --must-gather-output-dir=${ARTIFACT_DIR} "
fi

${RUN_COMMAND}
