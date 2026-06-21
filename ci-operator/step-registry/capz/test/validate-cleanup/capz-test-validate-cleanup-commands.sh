#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Phase 08: Validate Cleanup
# Validates cleanup operations for local and Azure resources.
# Produces JUnit XML in ${ARTIFACT_DIR} for Prow to collect.
export TEST_RESULTS_DIR="${ARTIFACT_DIR}"
script -e -q -c "make _validate-cleanup RESULTS_DIR=\"${ARTIFACT_DIR}\"" /dev/null

# Copy JUnit XMLs to SHARED_DIR for cross-step summary aggregation
cp "${ARTIFACT_DIR}"/junit-*.xml "${SHARED_DIR}/" 2>/dev/null || true
