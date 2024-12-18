#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

dastdir="/tmp/telco-dast-qe/tests/dast"
# set default values
WORKSPACE=${SHARED_DIR}
export KUBECONFIG=${WORKSPACE}/kubeconfig

# Unset environment variables which conflict with kubectl
unset NAMESPACE

# Execute test
chainsaw test \
--config "$dastdir/.chainsaw.yaml" \
--report-name "junit_telco_tests_dast" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir $dastdir