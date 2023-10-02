#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_STATUS=0

# only exit 0 if junit result has no failures
if [[ -f "${SHARED_DIR}/openshift-e2e-test-qe-report-openshift-extended-test-failures" ]]; then
    cat "${SHARED_DIR}/openshift-e2e-test-qe-report-openshift-extended-test-failures"
    echo "Please investigate these ginkgo test failures from build artifacts"
    let EXIT_STATUS+=1
fi

if [[ -f "${SHARED_DIR}/openshift-e2e-test-qe-report-cucushift-failures" ]]; then
    cat "${SHARED_DIR}/openshift-e2e-test-qe-report-cucushift-failures"
    echo "Please investigate these cucushift failures from build artifacts"
    let EXIT_STATUS+=2
fi

exit $EXIT_STATUS
