#!/bin/bash

set -o nounset
set -o pipefail

echo "Starting KServe inference tests"

TOOLS_DIR="/tmp/tools"
mkdir -p "${TOOLS_DIR}"
export PATH="${TOOLS_DIR}:${PATH}"

if ! command -v oc &>/dev/null; then
    echo "oc not found, downloading OpenShift client..."
    curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
        | tar xzf - -C "${TOOLS_DIR}" oc kubectl 2>/dev/null || true
fi

if ! command -v jq &>/dev/null; then
    echo "jq not found, downloading..."
    curl -sL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 -o "${TOOLS_DIR}/jq" \
        && chmod +x "${TOOLS_DIR}/jq" || true
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
mkdir -p "${ARTIFACT_DIR}"

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

echo "${ECO_HWACCEL_NEURON_DRIVER_VERSION:-unknown}" > "${ARTIFACT_DIR}/driver.version"
echo "Neuron Driver Version: ${ECO_HWACCEL_NEURON_DRIVER_VERSION:-unknown}"

if [[ -f "${CLUSTER_PROFILE_DIR}/hf-token" ]]; then
    export ECO_HWACCEL_NEURON_HF_TOKEN
    ECO_HWACCEL_NEURON_HF_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/hf-token")
    echo "HuggingFace token loaded from cluster profile"
fi

cd /home/testuser || exit 1

export ECO_TEST_FEATURES="neuron"
export ECO_TEST_LABELS="neuron && kserve"
export ECO_TEST_VERBOSE="true"
export ECO_DUMP_FAILED_TESTS="${ECO_DUMP_FAILED_TESTS:-true}"
export ECO_REPORTS_DUMP_DIR="${ARTIFACT_DIR}"

echo "Running KServe tests with labels: ${ECO_TEST_LABELS}"

TEST_EXIT_CODE=0

ginkgo --label-filter="${ECO_TEST_LABELS}" \
    --timeout=40m \
    --v \
    --keep-going \
    --junit-report=junit_neuron_kserve.xml \
    --output-dir="${ARTIFACT_DIR}" \
    ./tests/hw-accel/neuron/... || TEST_EXIT_CODE=$?

if [[ ${TEST_EXIT_CODE} -eq 0 ]]; then
    echo "SUCCESS" > "${ARTIFACT_DIR}/kserve_inference.status"
    echo "KServe inference tests passed"
else
    echo "FAILURE" > "${ARTIFACT_DIR}/kserve_inference.status"
    echo "KServe inference tests failed with exit code ${TEST_EXIT_CODE}"
fi

NEURON_OPERATOR_VERSION=$(oc get csv -A -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.name | test("neuron";"i"))] | .[0].spec.version // empty' || true)
if [[ -z "${NEURON_OPERATOR_VERSION}" ]]; then
    NEURON_OPERATOR_VERSION="${ECO_HWACCEL_NEURON_DEVICE_PLUGIN_IMAGE##*:}"
fi
NEURON_OPERATOR_VERSION="${NEURON_OPERATOR_VERSION:-unknown}"
echo "${NEURON_OPERATOR_VERSION}" > "${ARTIFACT_DIR}/operator.version"
echo "Neuron Operator Version: ${NEURON_OPERATOR_VERSION}"

echo "=== Collecting KServe debug info ==="
debug_dir="${ARTIFACT_DIR}/debug-kserve"
mkdir -p "${debug_dir}"

NS="${ECO_HWACCEL_NEURON_KSERVE_NAMESPACE:-neuron-inference}"
oc get inferenceservice -n "${NS}" -o yaml > "${debug_dir}/inferenceservices.yaml" 2>&1 || true
oc get servingruntime -n "${NS}" -o yaml > "${debug_dir}/servingruntimes.yaml" 2>&1 || true
oc get ksvc -n "${NS}" -o yaml > "${debug_dir}/knative-services.yaml" 2>&1 || true
oc get pods -n "${NS}" -o wide > "${debug_dir}/inference-pods.txt" 2>&1 || true
oc get events -n "${NS}" --sort-by='.lastTimestamp' > "${debug_dir}/inference-events.txt" 2>&1 || true
for pod in $(oc get pods -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
    oc describe pod -n "${NS}" "${pod}" > "${debug_dir}/${pod}-describe.txt" 2>&1 || true
    for container in $(oc get pod -n "${NS}" "${pod}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true); do
        oc logs -n "${NS}" "${pod}" -c "${container}" --tail=500 > "${debug_dir}/${pod}-${container}.log" 2>&1 || true
    done
done
oc get datasciencecluster -o yaml > "${debug_dir}/datasciencecluster.yaml" 2>&1 || true
echo "=== KServe debug info collected ==="

echo "KServe inference tests completed"
exit ${TEST_EXIT_CODE}
