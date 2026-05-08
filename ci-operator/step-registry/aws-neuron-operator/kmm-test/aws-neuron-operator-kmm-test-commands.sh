#!/bin/bash

set -o nounset
set -o pipefail

echo "Starting KMM sanity tests"

TOOLS_DIR="/tmp/tools"
mkdir -p "${TOOLS_DIR}"
export PATH="${TOOLS_DIR}:${PATH}"

if ! command -v oc &>/dev/null; then
    echo "oc not found, downloading OpenShift client..."
    curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
        | tar xzf - -C "${TOOLS_DIR}" oc kubectl 2>/dev/null || true
    if command -v oc &>/dev/null; then
        echo "oc installed: $(oc version --client 2>/dev/null || echo 'ok')"
    else
        echo "WARNING: failed to install oc"
    fi
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
mkdir -p "${ARTIFACT_DIR}"

# Load KMM pull secret from cluster profile if available
if [[ -f "${CLUSTER_PROFILE_DIR}/kmm-pull-secret" ]]; then
    export ECO_HWACCEL_KMM_PULL_SECRET
    ECO_HWACCEL_KMM_PULL_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/kmm-pull-secret")
    echo "KMM pull secret loaded from cluster profile"
else
    echo "WARNING: No KMM pull secret found, tests requiring external registry may be skipped"
fi

cd /home/testuser || exit 1

export ECO_TEST_FEATURES="${KMM_TEST_FEATURES:-modules}"
export ECO_TEST_LABELS="${KMM_TEST_LABELS:-kmm-sanity && !bmc}"
export ECO_TEST_VERBOSE="true"
export ECO_DUMP_FAILED_TESTS="${ECO_DUMP_FAILED_TESTS:-true}"
export ECO_REPORTS_DUMP_DIR="${ARTIFACT_DIR}"

echo "Running KMM tests with features: ${ECO_TEST_FEATURES}"
echo "Running KMM tests with labels: ${ECO_TEST_LABELS}"

TEST_EXIT_CODE=0

ginkgo --label-filter="${ECO_TEST_LABELS}" \
    --timeout=1h \
    --v \
    --keep-going \
    --junit-report=junit_kmm_modules.xml \
    --output-dir="${ARTIFACT_DIR}" \
    ./tests/hw-accel/kmm/modules/... || TEST_EXIT_CODE=$?

if [[ ${TEST_EXIT_CODE} -eq 0 ]]; then
    echo "SUCCESS" > "${ARTIFACT_DIR}/kmm_sanity.status"
    echo "KMM sanity tests passed"
else
    echo "FAILURE" > "${ARTIFACT_DIR}/kmm_sanity.status"
    echo "KMM sanity tests failed with exit code ${TEST_EXIT_CODE}"
fi

echo "=== Collecting KMM debug info ==="
debug_dir="${ARTIFACT_DIR}/debug-kmm"
mkdir -p "${debug_dir}"
oc get modules.kmm.sigs.x-k8s.io -A -o yaml > "${debug_dir}/kmm-modules.yaml" 2>&1 || true
oc get pods -n openshift-kmm -o wide > "${debug_dir}/kmm-pods.txt" 2>&1 || true
oc logs -n openshift-kmm -l app.kubernetes.io/component=kmm --tail=500 > "${debug_dir}/kmm-operator-logs.txt" 2>&1 || true
oc get events -n openshift-kmm --sort-by='.lastTimestamp' > "${debug_dir}/kmm-events.txt" 2>&1 || true
oc get csv -n openshift-kmm -o yaml > "${debug_dir}/kmm-csvs.yaml" 2>&1 || true
oc get daemonsets -n openshift-kmm -o wide > "${debug_dir}/kmm-daemonsets.txt" 2>&1 || true
echo "=== KMM debug info collected ==="

echo "KMM sanity tests completed"
exit ${TEST_EXIT_CODE}
