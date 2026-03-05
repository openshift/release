#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO(debug): remove this block for final pr {{{
git clone --depth 1 -b "${DAST_TEST_BRANCH}" "${DAST_TEST_REPO}" /tmp/telco-dast-qe-override
# }}} end debug block

# TODO(debug): change back to /tmp/telco-dast-qe for final pr
dastdir="/tmp/telco-dast-qe-override/tests/dast"

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