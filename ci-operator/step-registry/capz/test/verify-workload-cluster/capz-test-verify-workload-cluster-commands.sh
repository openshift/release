#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
source "${SHARED_DIR}/capz-test-env.sh"

export INIT_KIND=false
export USE_KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ -d "${ARO_REPO_DIR}" ]]; then
  echo "Repository already exists at ${ARO_REPO_DIR}"
else
  echo "Cloning ${ARO_REPO_URL} branch ${ARO_REPO_BRANCH} into ${ARO_REPO_DIR}"
  git clone -b "${ARO_REPO_BRANCH}" "${ARO_REPO_URL}" "${ARO_REPO_DIR}"
fi

# Restore generated YAMLs from SHARED_DIR (copied by generate-yamls step).
OUTPUT_DIR="${ARO_REPO_DIR}/${WORKLOAD_CLUSTER_NAME:-capz-tests}-${DEPLOYMENT_ENV}"
if ls "${SHARED_DIR}"/generated-*.yaml 1>/dev/null 2>&1; then
  mkdir -p "${OUTPUT_DIR}"
  for f in "${SHARED_DIR}"/generated-*.yaml; do
    cp "${f}" "${OUTPUT_DIR}/$(basename "${f}" | sed 's/^generated-//')"
  done
fi

export TEST_RESULTS_DIR="${ARTIFACT_DIR}"
script -e -q -c "make _verify-workload-cluster RESULTS_DIR=\"${ARTIFACT_DIR}\"" /dev/null

# Copy JUnit XMLs to SHARED_DIR for cross-step summary aggregation
cp "${ARTIFACT_DIR}"/junit-*.xml "${SHARED_DIR}/" 2>/dev/null || true
