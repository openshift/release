#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Phase 03: Management Cluster
# With USE_KUBECONFIG set, skips Kind creation and validates the external cluster
# with CAPI/CAPZ/ASO controllers (deployed via DEPLOY_CHARTS=true).
export TEST_RESULTS_DIR="${ARTIFACT_DIR}"
script -e -q -c "make _management_cluster RESULTS_DIR=\"${ARTIFACT_DIR}\"" /dev/null

# Copy JUnit XMLs to SHARED_DIR for cross-step summary aggregation
cp "${ARTIFACT_DIR}"/junit-*.xml "${SHARED_DIR}/" 2>/dev/null || true
