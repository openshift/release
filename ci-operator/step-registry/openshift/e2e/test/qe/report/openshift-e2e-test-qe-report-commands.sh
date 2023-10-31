#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results"

# the exit code of this step is not expected to be caught from the overall test suite in RP. Excluding it
touch "${ARTIFACT_DIR}/skip_overall_if_fail"

if [[ -f "${SHARED_DIR}/openshift-e2e-test-qe-report-openshift-extended-test-results" ]] ; then
    echo
    cat "${SHARED_DIR}/openshift-e2e-test-qe-report-openshift-extended-test-results" | tee -a "${TEST_RESULT_FILE}"
fi

if [[ -f "${SHARED_DIR}/openshift-e2e-test-qe-report-cucushift-results" ]] ; then
    echo
    cat "${SHARED_DIR}/openshift-e2e-test-qe-report-cucushift-results" | tee -a "${TEST_RESULT_FILE}"
fi


# only exit 0 if rest result has no 'Failing Scenarios:'
if [[ -f "${TEST_RESULT_FILE}" ]] ; then
    if (grep -q 'Failing Scenarios:' "${TEST_RESULT_FILE}") ; then
        exit 1
    fi
fi
