#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

# Extract clusters archive from SHARED_DIR
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data

RUN_COMMAND="poetry run pytest tests \
            -s -o log_cli=true \
            --junit-xml='${ARTIFACT_DIR}/xunit_results.xml' \
            --pytest-log-file='${ARTIFACT_DIR}/pytest-tests.log' \
            -m ${TEST_MARKER} \
            --data-collector=data-collector_containerized.yaml"
KUBECONFIG_COMMAND="--kubeconfig-file-paths="${KUBECONFIG1_PATH},${KUBECONFIG2_PATH},${KUBECONFIG3_PATH}" "

RUN_COMMAND+=" ${KUBECONFIG_COMMAND} "

echo "$RUN_COMMAND"

${RUN_COMMAND}
