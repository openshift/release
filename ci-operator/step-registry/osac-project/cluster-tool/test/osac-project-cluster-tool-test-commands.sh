#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ cluster-tool vmaas test ************"
echo "Running ALL vmaas tests sequentially"
echo "OSAC_TEST_IMAGE: ${OSAC_TEST_IMAGE}"
echo "E2E_NAMESPACE: ${E2E_NAMESPACE}"
echo "E2E_VM_TEMPLATE: ${E2E_VM_TEMPLATE}"
echo "-------------------------------------------"

CLONE_NAME="ci-test"
KUBECONFIG_PATH="/root/.kube/${CLONE_NAME}.kubeconfig"
REMOTE_RESULTS_DIR="/tmp/test-results"

function collect_artifacts() {
    echo "Collecting test artifacts..."
    timeout -s 9 2m scp -F "${SHARED_DIR}/ssh_config" \
        "ci_machine:${REMOTE_RESULTS_DIR}/junit_vmaas.xml" \
        "${ARTIFACT_DIR}/junit_vmaas.xml" 2>/dev/null || true
}
trap collect_artifacts EXIT

TEST_EXIT=0
timeout -s 9 60m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
    "${E2E_NAMESPACE}" \
    "${E2E_VM_TEMPLATE}" \
    "${E2E_CLUSTER_TEMPLATE}" \
    "${OSAC_TEST_IMAGE}" \
    "${KUBECONFIG_PATH}" \
    "${REMOTE_RESULTS_DIR}" \
    <<'REMOTE_EOF' || TEST_EXIT=$?
set -euo pipefail

NAMESPACE="$1"
VM_TEMPLATE="$2"
CLUSTER_TEMPLATE="$3"
TEST_IMAGE="$4"
KUBECONFIG_PATH="$5"
RESULTS_DIR="$6"

mkdir -p "${RESULTS_DIR}"

export KUBECONFIG="${KUBECONFIG_PATH}"
echo "Waiting for KubeVirt to be Available..."
for attempt in $(seq 1 60); do
    AVAILABLE=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
    if [[ "${AVAILABLE}" == "True" ]]; then
        echo "  KubeVirt Available after $((attempt * 10))s"
        break
    fi
    if [[ $((attempt % 6)) -eq 0 ]]; then
        PROGRESSING=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.conditions[?(@.type=="Progressing")].message}' 2>/dev/null || echo "unknown")
        echo "  [${attempt}0s] KubeVirt not Available yet: ${PROGRESSING}"
    fi
    sleep 10
done
if [[ "${AVAILABLE}" != "True" ]]; then
    echo "ERROR: KubeVirt not Available after 600s"
    oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o yaml 2>/dev/null || true
    exit 1
fi
unset KUBECONFIG

echo "Running vmaas tests..."
podman run --authfile /root/pull-secret --rm --network=host \
    -v "${KUBECONFIG_PATH}":/root/.kube/config:z \
    -v /root/pull-secret:/root/pull-secret:z \
    -v "${RESULTS_DIR}":/tmp/test-results:z \
    -e KUBECONFIG=/root/.kube/config \
    -e OSAC_VM_KUBECONFIG=/root/.kube/config \
    -e OSAC_NAMESPACE="${NAMESPACE}" \
    -e OSAC_VM_TEMPLATE="${VM_TEMPLATE}" \
    -e OSAC_CLUSTER_TEMPLATE="${CLUSTER_TEMPLATE}" \
    -e OSAC_PULL_SECRET_PATH=/root/pull-secret \
    "${TEST_IMAGE}" \
    pytest tests/vmaas/ -v --junitxml=/tmp/test-results/junit_vmaas.xml

echo "Tests completed."
REMOTE_EOF

if [[ "${TEST_EXIT}" -ne 0 ]]; then
    echo "Some tests failed (exit code: ${TEST_EXIT})"
    exit "${TEST_EXIT}"
fi

echo "All tests passed."
