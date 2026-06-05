#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Running OSAC E2E tests: suite=${TEST_SUITE}"

REMOTE_RESULTS_DIR="/tmp/test-results"

function collect_artifacts() {
    echo "Collecting test artifacts..."
    timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
        "ci_machine:${REMOTE_RESULTS_DIR}/junit_${TEST_SUITE}.xml" \
        "${ARTIFACT_DIR}/junit_${TEST_SUITE}.xml" 2>/dev/null || true
}
trap collect_artifacts EXIT

TEST_EXIT=0
timeout -s 9 60m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
    "${TEST_SUITE}" \
    "${E2E_NAMESPACE}" \
    "${E2E_VM_TEMPLATE}" \
    "${E2E_CLUSTER_TEMPLATE}" \
    "${OSAC_TEST_IMAGE}" \
    "${REMOTE_RESULTS_DIR}" \
    <<'REMOTE_EOF' || TEST_EXIT=$?
set -euo pipefail

TEST_SUITE="$1"
E2E_NAMESPACE="$2"
E2E_VM_TEMPLATE="$3"
E2E_CLUSTER_TEMPLATE="$4"
OSAC_TEST_IMAGE="$5"
RESULTS_DIR="$6"

mkdir -p "${RESULTS_DIR}"

KUBECONFIG=$(find ${KUBECONFIG} -type f -print -quit 2>/dev/null)
[[ -z "${KUBECONFIG}" ]] && echo "ERROR: No kubeconfig found" && exit 1

PULL_SECRET_PATH="/root/pull-secret"

set +x
podman run --authfile "${PULL_SECRET_PATH}" --rm --network=host \
  -v "${KUBECONFIG}:/root/.kube/config:z" \
  -v "${PULL_SECRET_PATH}:/root/pull-secret:z" \
  -v "${RESULTS_DIR}":/tmp/test-results:z \
  -e KUBECONFIG=/root/.kube/config \
  -e OSAC_VM_KUBECONFIG=/root/.kube/config \
  -e OSAC_NAMESPACE="${E2E_NAMESPACE}" \
  -e OSAC_VM_TEMPLATE="${E2E_VM_TEMPLATE}" \
  -e OSAC_CLUSTER_TEMPLATE="${E2E_CLUSTER_TEMPLATE}" \
  -e OSAC_PULL_SECRET_PATH=/root/pull-secret \
  "${OSAC_TEST_IMAGE}" \
  pytest "tests/${TEST_SUITE}/" -v --junitxml="/tmp/test-results/junit_${TEST_SUITE}.xml"
REMOTE_EOF

if [[ "${TEST_EXIT}" -ne 0 ]]; then
    echo "Some tests failed (exit code: ${TEST_EXIT})"
    exit "${TEST_EXIT}"
fi

echo "All tests passed."
