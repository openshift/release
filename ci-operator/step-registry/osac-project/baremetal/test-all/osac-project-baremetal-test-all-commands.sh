#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Running ALL vmaas E2E tests"

REMOTE_RESULTS_DIR="/tmp/test-results"

function collect_artifacts() {
    echo "Collecting test artifacts..."
    timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
        "ci_machine:${REMOTE_RESULTS_DIR}/junit_vmaas.xml" \
        "${ARTIFACT_DIR}/junit_vmaas.xml" 2>/dev/null || true
}
trap collect_artifacts EXIT

echo "Collecting deployed component versions..."
ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${E2E_NAMESPACE}" <<'VERSION_EOF' > "${SHARED_DIR}/versions.txt"
KUBECONFIG=$(find ${KUBECONFIG} -type f -print -quit 2>/dev/null)
NS="$1"
for deploy in fulfillment-grpc-server fulfillment-controller osac-operator-controller-manager; do
    IMG=$(oc get deploy "${deploy}" -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || continue
    echo "${deploy}=${IMG}"
done
VERSION_EOF
echo "Versions written to SHARED_DIR"

TEST_EXIT=0
timeout -s 9 90m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
    "${E2E_NAMESPACE}" \
    "${E2E_VM_TEMPLATE}" \
    "${E2E_CLUSTER_TEMPLATE}" \
    "${OSAC_TEST_IMAGE}" \
    "${REMOTE_RESULTS_DIR}" \
    <<'REMOTE_EOF' || TEST_EXIT=$?
set -euo pipefail

NAMESPACE="$1"
VM_TEMPLATE="$2"
CLUSTER_TEMPLATE="$3"
TEST_IMAGE="$4"
RESULTS_DIR="$5"

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
    -e OSAC_NAMESPACE="${NAMESPACE}" \
    -e OSAC_VM_TEMPLATE="${VM_TEMPLATE}" \
    -e OSAC_CLUSTER_TEMPLATE="${CLUSTER_TEMPLATE}" \
    -e OSAC_PULL_SECRET_PATH=/root/pull-secret \
    "${TEST_IMAGE}" \
    make test-vmaas
REMOTE_EOF

if [[ "${TEST_EXIT}" -ne 0 ]]; then
    echo "FAILED" > "${SHARED_DIR}/test-result"
    echo "Some tests failed (exit code: ${TEST_EXIT})"
    exit "${TEST_EXIT}"
fi

echo "PASSED" > "${SHARED_DIR}/test-result"
echo "All tests passed."
