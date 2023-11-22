#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

sleep 2h

KUBECONFIG="${HUB_CLUSTER_DATA_DIR}/kubeconfig"
KUBEADMIN_TOKEN=$(cat ${HUB_CLUSTER_DATA_DIR}/kubeadmin-token)

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