#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
source openshift-ci/capz-test-env.sh

export TEST_RESULTS_DIR="${ARTIFACT_DIR}"
script -e -q -c "make _validate-cleanup RESULTS_DIR=\"${ARTIFACT_DIR}\"" /dev/null

# Copy JUnit XMLs to SHARED_DIR for cross-step summary aggregation
cp "${ARTIFACT_DIR}"/junit-*.xml "${SHARED_DIR}/" 2>/dev/null || true
