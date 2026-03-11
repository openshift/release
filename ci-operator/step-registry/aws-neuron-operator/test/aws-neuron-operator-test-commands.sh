#!/bin/bash

set -o nounset
set -o pipefail

echo "Starting AWS Neuron operator E2E tests"

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

echo "=== Phase 2: Metrics tests ==="
ginkgo --label-filter="${ECO_TEST_LABELS} && metrics" \
    --timeout=30m \
    --v \
    --junit-report=junit_neuron_metrics.xml \
    --output-dir="${ARTIFACT_DIR}" \
    ./tests/hw-accel/neuron/... || TEST_EXIT_CODE=$?

echo "=== Phase 3: Upgrade tests ==="
ginkgo --label-filter="${ECO_TEST_LABELS} && upgrade" \
    --timeout=1h \
    --v \
    --junit-report=junit_neuron_upgrade.xml \
    --output-dir="${ARTIFACT_DIR}" \
    ./tests/hw-accel/neuron/... || TEST_EXIT_CODE=$?

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
