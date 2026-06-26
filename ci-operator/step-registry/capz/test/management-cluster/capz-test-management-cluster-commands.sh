#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
source "${SHARED_DIR}/capz-test-env.sh"

export INIT_KIND=false
export USE_KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ -f "${SHARED_DIR}/dev_endpoint" ]]; then
  DEV_ENDPOINT=$(cat "${SHARED_DIR}/dev_endpoint")
  export DEV_ENDPOINT
  echo "DEV_ENDPOINT loaded: ${DEV_ENDPOINT}"
fi

if [[ -d "${ARO_REPO_DIR}" ]]; then
  echo "Repository already exists at ${ARO_REPO_DIR}"
else
  echo "Cloning ${ARO_REPO_URL} branch ${ARO_REPO_BRANCH} into ${ARO_REPO_DIR}"
  git clone -b "${ARO_REPO_BRANCH}" "${ARO_REPO_URL}" "${ARO_REPO_DIR}"
fi

# Phase 03: Management Cluster
# With USE_KUBECONFIG set, skips Kind creation and validates the external cluster
# with CAPI/CAPZ/ASO controllers (deployed via DEPLOY_CHARTS=true).
export TEST_RESULTS_DIR="${ARTIFACT_DIR}"
script -e -q -c "make _management_cluster RESULTS_DIR=\"${ARTIFACT_DIR}\"" /dev/null

# Copy JUnit XMLs to SHARED_DIR for cross-step summary aggregation
cp "${ARTIFACT_DIR}"/junit-*.xml "${SHARED_DIR}/" 2>/dev/null || true
