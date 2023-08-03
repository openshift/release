#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

# Extract clusters archive from SHARED_DIR
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data

RUN_COMMAND="poetry run pytest tests \
            -s -o log_cli=true --pdb \
            --junit-xml='${ARTIFACT_DIR}/xunit_results.xml' \
            --pytest-log-file='${ARTIFACT_DIR}/pytest-tests.log' \
            -m ${TEST_MARKER} \
            --data-collector=data-collector-openshift-ci.yaml --trace"
KUBECONFIG_COMMAND="--kubeconfig-file-paths="${CLUSTER1_KUBECONFIG_PATH},${CLUSTER2_KUBECONFIG_PATH}" "

RUN_COMMAND+=" ${KUBECONFIG_COMMAND} "

echo "$RUN_COMMAND"

sleep 50000000

${RUN_COMMAND}
