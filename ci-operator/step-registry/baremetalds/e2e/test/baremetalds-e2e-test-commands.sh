#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Baremetal DS test commands executed"

#test_suite=openshift/conformance/parallel
#if [[ -e "${SHARED_DIR}/test-suite.txt" ]]; then
#    test_suite=$(<"${SHARED_DIR}/test-suite.txt")
#fi
#
#openshift-tests run "${test_suite}" \
#    --provider "${TEST_PROVIDER}" \
#    -o /tmp/artifacts/e2e.log \
#    --junit-dir /tmp/artifacts/junit
