#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# the exit code of this step is not expected to be caught from the overall test suite in RP. Excluding it
touch "${ARTIFACT_DIR}/skip_overall_if_fail"

TEST_REPORT_FILE='openshift-e2e-test-qe-report'
if [[ -f "${SHARED_DIR}/${TEST_REPORT_FILE}" ]] ; then
    cat "${SHARED_DIR}/${TEST_REPORT_FILE}"
    cp "${SHARED_DIR}/${TEST_REPORT_FILE}" "${ARTIFACT_DIR}/${TEST_REPORT_FILE}" || true

    # only exit 0 if rest result has no 'Failing Scenarios:'
    if (grep -q 'Failing Scenarios:' "${ARTIFACT_DIR}/${TEST_REPORT_FILE}") ; then
        exit 1
    fi
fi
