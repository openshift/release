#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

export KUBECONFIG=${SHARED_DIR}/kubeconfig

RUN_COMMAND="poetry run pytest tests \
            -o log_cli=true \
            --junit-xml=${ARTIFACT_DIR}/xunit_results.xml \
            --pytest-log-file=${ARTIFACT_DIR}/pytest-tests.log \
            -m ${TEST_MARKER} \
            --data-collector=data-collector-openshift-ci.yaml "

echo "$RUN_COMMAND"

${RUN_COMMAND}
