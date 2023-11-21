#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

KUBECONFIG=$(cat $HUB_CLUSTER_DATA_PATH | yq .kubeconfig_path)
KUBEADMIN_TOKEN=$(cat $HUB_CLUSTER_DATA_PATH | yq .kubeadmin_token)

export KUBECONFIG
export KUBEADMIN_TOKEN

RUN_COMMAND="poetry run pytest tests \
            -o log_cli=true \
            --junit-xml=${ARTIFACT_DIR}/xunit_results.xml \
            --pytest-log-file=${ARTIFACT_DIR}/pytest-tests.log \
            -m ${TEST_MARKER} \
            --cluster-name=${HUB_CLUSTER_NAME} \
            --data-collector=data-collector-openshift-ci.yaml"

echo "$RUN_COMMAND"

${RUN_COMMAND}