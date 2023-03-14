#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

sleep 500000

OUTPUT_DIR=${ARTIFACT_DIR}
CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)

export KUBECONFIG=${SHARED_DIR}/kubeconfig
export OCM_TOKEN=${OCM_TOKEN}

poetry run pytest --tc=api_server:"{ROSA_ENV}" --cluster-name "${CLUSTER_NAME}" --junitxml="${OUTPUT_DIR}/xunit_results.xml" \
--pytest-log-file="${OUTPUT_DIR}/pytest-tests.log" -s -o log_cli=true -p no:logging -m "$TEST_MARKERS"  --data-collector=data-collector.yaml
