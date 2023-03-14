#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

OUTPUT_DIR=${ARTIFACT_DIR}
CLUSTER_NAME=$(cat "${SHARED_DIR}/CLUSTER_NAME")

export KUBECONFIG=${SHARED_DIR}/kubeconfig

poetry run pytest --tc=api_server:production --cluster-name "${CLUSTER_NAME}" --junitxml="${OUTPUT_DIR}/xunit_results.xml" \
--pytest-log-file="${OUTPUT_DIR}/pytest-tests.log" -s -o log_cli=true -p no:logging -m "$TEST_MARKERS"  --data-collector=data-collector.yaml
