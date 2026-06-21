#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Phase 05: Deploy CRs
# Applies cluster resources and waits for control plane deployment.
# Produces JUnit XML in ${ARTIFACT_DIR} for Prow to collect.
# Restore generated YAMLs from SHARED_DIR (copied by generate-yamls step).
# Each Prow step runs in a separate container; /tmp is not shared between them.
OUTPUT_DIR="${ARO_REPO_DIR}/${WORKLOAD_CLUSTER_NAME:-capz-tests}-${DEPLOYMENT_ENV}"
if ls "${SHARED_DIR}"/generated-*.yaml 1>/dev/null 2>&1; then
  mkdir -p "${OUTPUT_DIR}"
  for f in "${SHARED_DIR}"/generated-*.yaml; do
    cp "${f}" "${OUTPUT_DIR}/$(basename "${f}" | sed 's/^generated-//')"
  done
  echo "Restored generated YAMLs to ${OUTPUT_DIR}"
  ls -la "${OUTPUT_DIR}/"
fi

export TEST_RESULTS_DIR="${ARTIFACT_DIR}"
script -e -q -c "make _deploy-crs RESULTS_DIR=\"${ARTIFACT_DIR}\"" /dev/null

# Copy JUnit XMLs to SHARED_DIR for cross-step summary aggregation
cp "${ARTIFACT_DIR}"/junit-*.xml "${SHARED_DIR}/" 2>/dev/null || true
