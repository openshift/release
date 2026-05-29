#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Diagnostic: print the capi-tests commit so we can verify which version CI used
echo "=== capi-tests source commit ==="
git log --oneline -1 || echo "(not a git repo)"
echo "================================"

# Phase 04: Generate YAMLs
# Generates credential and cluster YAML manifests for deployment.
# Produces JUnit XML in ${ARTIFACT_DIR} for Prow to collect.
export TEST_RESULTS_DIR="${ARTIFACT_DIR}"
script -e -q -c "make _generate-yamls RESULTS_DIR=\"${ARTIFACT_DIR}\"" /dev/null

# Diagnostic: show ARO_REPO_DIR contents after generation
echo "=== ARO_REPO_DIR contents ==="
ls -la "${ARO_REPO_DIR}/" | head -20
echo "============================================="

# Copy generated YAMLs to SHARED_DIR so they persist for the deploy-crs step.
# Each Prow step runs in a separate container; /tmp is not shared between them.
OUTPUT_DIR="${ARO_REPO_DIR}/${WORKLOAD_CLUSTER_NAME:-capz-tests}-${DEPLOYMENT_ENV}"
if [[ -d "${OUTPUT_DIR}" ]]; then
  for f in "${OUTPUT_DIR}"/*; do
    basename_f="$(basename "${f}")"
    # Always copy to SHARED_DIR (raw, needed for deploy-crs step)
    cp "${f}" "${SHARED_DIR}/generated-${basename_f}"
    # Skip credential files from public artifacts
    case "${basename_f}" in
      credentials.yaml)
        echo "# Redacted - contains Kubernetes Secret resources" > "${ARTIFACT_DIR}/${basename_f}"
        echo "[generate-yamls] ${basename_f} excluded from artifacts (contains secrets)"
        ;;
      *)
        cp "${f}" "${ARTIFACT_DIR}/"
        ;;
    esac
  done
  echo "Copied generated YAMLs to SHARED_DIR and ARTIFACT_DIR (credentials redacted)"
  ls -la "${SHARED_DIR}"/generated-*
fi

# Copy JUnit XMLs to SHARED_DIR for cross-step summary aggregation
cp "${ARTIFACT_DIR}"/junit-*.xml "${SHARED_DIR}/" 2>/dev/null || true
