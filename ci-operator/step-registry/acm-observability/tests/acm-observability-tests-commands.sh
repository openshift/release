#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

# Extract clusters archive from SHARED_DIR
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data

KUBECONFIG="${HUB_CLUSTER_DATA_DIR}/auth/kubeconfig"
export KUBECONFIG

RUN_COMMAND="poetry run pytest tests \
            -o log_cli=true \
            --junit-xml=${ARTIFACT_DIR}/xunit_results.xml \
            --pytest-log-file=${ARTIFACT_DIR}/pytest-tests.log \
            -m ${TEST_MARKER} \
            --cluster-name=${HUB_CLUSTER_NAME} \
            --data-collector=data-collector-openshift-ci.yaml"

echo "$RUN_COMMAND"

${RUN_COMMAND}