#!/bin/bash

set -o nounset
set -o pipefail

echo "Starting AWS Neuron operator E2E tests"

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

if ! command -v jq &>/dev/null; then
    echo "jq not found, downloading..."
    curl -sL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o "${TOOLS_DIR}/jq" \
        && chmod +x "${TOOLS_DIR}/jq" || true
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
mkdir -p "${ARTIFACT_DIR}"

# Determine OCP version using multiple fallback methods (ROSA HCP may restrict clusterversion access)
OCP_VERSION=""
OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
if [[ -z "${OCP_VERSION}" && -f "${SHARED_DIR}/ocp-version" ]]; then
    OCP_VERSION=$(cat "${SHARED_DIR}/ocp-version")
fi
if [[ -z "${OCP_VERSION}" ]]; then
    OCP_VERSION=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // empty' || true)
fi
OCP_VERSION="${OCP_VERSION:-unknown}"
echo "${OCP_VERSION}" > "${ARTIFACT_DIR}/ocp.version"
echo "OCP Version: ${OCP_VERSION}"

# Write driver version from env var (available before tests install the operator)
echo "${ECO_HWACCEL_NEURON_DRIVER_VERSION:-unknown}" > "${ARTIFACT_DIR}/driver.version"
echo "Neuron Driver Version: ${ECO_HWACCEL_NEURON_DRIVER_VERSION:-unknown}"

if [[ -f "${CLUSTER_PROFILE_DIR}/hf-token" ]]; then
    export ECO_HWACCEL_NEURON_HF_TOKEN
    ECO_HWACCEL_NEURON_HF_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/hf-token")
    echo "HuggingFace token loaded from cluster profile"
fi

cd /home/testuser || exit 1

dump_debug_info() {
    local phase="${1:-unknown}"
    local dump_dir="${ARTIFACT_DIR}/debug-${phase}"
    mkdir -p "${dump_dir}"
    echo "=== Collecting debug info for ${phase} ==="

    oc get modules.kmm.sigs.x-k8s.io -A -o yaml > "${dump_dir}/kmm-modules.yaml" 2>&1 || true
    oc get pods -A -o wide > "${dump_dir}/all-pods.txt" 2>&1 || true
    oc get pods -n openshift-kmm -o wide > "${dump_dir}/kmm-pods.txt" 2>&1 || true
    oc get daemonsets -A -o wide > "${dump_dir}/daemonsets.txt" 2>&1 || true
    oc get events -A --sort-by='.lastTimestamp' > "${dump_dir}/events.txt" 2>&1 || true
    oc get nodes -o json | jq '.items[].status.images[] | select(.names[] | test("neuron"))' > "${dump_dir}/node-neuron-images.json" 2>&1 || true
    oc describe nodes > "${dump_dir}/nodes-describe.txt" 2>&1 || true
    oc get csv -A > "${dump_dir}/csvs.txt" 2>&1 || true
    oc get subscriptions -A -o yaml > "${dump_dir}/subscriptions.yaml" 2>&1 || true

    oc logs -n openshift-kmm -l app.kubernetes.io/component=kmm --tail=500 > "${dump_dir}/kmm-operator-logs.txt" 2>&1 || true

    local neuron_ns
    neuron_ns=$(oc get pods -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | test("neuron")) | .metadata.namespace' | head -1 || true)
    if [[ -n "${neuron_ns}" ]]; then
        oc logs -n "${neuron_ns}" -l app.kubernetes.io/name=aws-neuron-operator --tail=500 > "${dump_dir}/neuron-operator-logs.txt" 2>&1 || true
        oc get all -n "${neuron_ns}" -o wide > "${dump_dir}/neuron-ns-resources.txt" 2>&1 || true
    fi

    echo "=== Debug info collected in ${dump_dir} ==="
}

export ECO_TEST_FEATURES="${ECO_TEST_FEATURES:-neuron}"
export ECO_TEST_LABELS="${ECO_TEST_LABELS:-neuron}"

echo "Running tests with features: ${ECO_TEST_FEATURES}"
echo "Running tests with labels: ${ECO_TEST_LABELS}"

# Run test suites in explicit order: vllm -> metrics -> upgrade
# Each suite gets its own jUnit report for granular results.
TEST_EXIT_CODE=0

echo "=== Phase 1: vLLM inference tests ==="
ginkgo --label-filter="${ECO_TEST_LABELS} && vllm" \
    --timeout=1h \
    --v \
    --junit-report=junit_neuron_vllm.xml \
    --output-dir="${ARTIFACT_DIR}" \
    ./tests/hw-accel/neuron/... || TEST_EXIT_CODE=$?
dump_debug_info "phase1-vllm"

echo "=== Phase 2: Metrics tests ==="
ginkgo --label-filter="${ECO_TEST_LABELS} && metrics" \
    --timeout=30m \
    --v \
    --junit-report=junit_neuron_metrics.xml \
    --output-dir="${ARTIFACT_DIR}" \
    ./tests/hw-accel/neuron/... || TEST_EXIT_CODE=$?
dump_debug_info "phase2-metrics"

echo "=== Phase 3: Upgrade tests ==="
ginkgo --label-filter="${ECO_TEST_LABELS} && upgrade" \
    --timeout=1h \
    --v \
    --junit-report=junit_neuron_upgrade.xml \
    --output-dir="${ARTIFACT_DIR}" \
    ./tests/hw-accel/neuron/... || TEST_EXIT_CODE=$?
dump_debug_info "phase3-upgrade"

# Write operator version after tests (operator is deployed during test execution)
NEURON_CSV=$(oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i neuron | head -1 || echo "")
if [[ -n "${NEURON_CSV}" ]]; then
    NEURON_OPERATOR_VERSION=$(oc get csv -A "${NEURON_CSV}" -o jsonpath='{.spec.version}' 2>/dev/null || echo "unknown")
else
    NEURON_OPERATOR_VERSION="${ECO_HWACCEL_NEURON_DEVICE_PLUGIN_IMAGE##*:}"
fi
echo "${NEURON_OPERATOR_VERSION}" > "${ARTIFACT_DIR}/operator.version"
echo "Neuron Operator Version: ${NEURON_OPERATOR_VERSION}"

echo "AWS Neuron operator E2E tests completed"
exit ${TEST_EXIT_CODE}
