#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO(debug): remove this block for final pr {{{
rm -rf /tmp/telco-dast-qe
git clone --depth 1 -b "${DAST_TEST_BRANCH}" "${DAST_TEST_REPO}" /tmp/telco-dast-qe
# }}} end debug block

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