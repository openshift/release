#!/bin/bash

set -o nounset
set -o pipefail

echo "Starting AWS Neuron DRA E2E tests"

TOOLS_DIR="/tmp/tools"
mkdir -p "${TOOLS_DIR}" "${ARTIFACT_DIR}"
export PATH="${TOOLS_DIR}:${PATH}"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if ! command -v oc &>/dev/null; then
    curl -sL https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
        | tar xzf - -C "${TOOLS_DIR}" oc kubectl
fi

if ! command -v jq &>/dev/null; then
    curl -sL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 \
        -o "${TOOLS_DIR}/jq"
    chmod +x "${TOOLS_DIR}/jq"
fi

if [[ -f "${SHARED_DIR}/neuron-deviceconfig.env" ]]; then
    source "${SHARED_DIR}/neuron-deviceconfig.env"
fi

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
if [[ -z "${OCP_VERSION}" && -f "${SHARED_DIR}/ocp-version" ]]; then
    OCP_VERSION=$(<"${SHARED_DIR}/ocp-version")
fi
OCP_VERSION="${OCP_VERSION:-unknown}"
echo "${OCP_VERSION}" > "${ARTIFACT_DIR}/ocp.version"

echo "${ECO_HWACCEL_NEURON_DRIVER_VERSION:-unknown}" > "${ARTIFACT_DIR}/driver.version"
echo "${ECO_HWACCEL_NEURON_DRA_DRIVER_IMAGE##*:}" > "${ARTIFACT_DIR}/dra-driver.version"

NEURON_OPERATOR_VERSION=$(oc get csv -n aws-neuron-operator -o json 2>/dev/null \
    | jq -r '[.items[] | select(.metadata.name | startswith("aws-neuron-operator."))][0].spec.version // empty' || true)
echo "${NEURON_OPERATOR_VERSION:-unknown}" > "${ARTIFACT_DIR}/operator.version"

if [[ -f "${CLUSTER_PROFILE_DIR}/hf-token" ]]; then
    export ECO_HWACCEL_NEURON_HF_TOKEN
    ECO_HWACCEL_NEURON_HF_TOKEN=$(<"${CLUSTER_PROFILE_DIR}/hf-token")
    echo "HuggingFace token loaded from cluster profile"
fi

export ECO_TEST_FEATURES="${ECO_TEST_FEATURES:-neuron}"
export ECO_TEST_LABELS="${ECO_TEST_LABELS:-neuron-dra}"
export ECO_DUMP_FAILED_TESTS=true
export ECO_REPORTS_DUMP_DIR="${ARTIFACT_DIR}"

cd /home/testuser || exit 1

ginkgo --label-filter="${ECO_TEST_LABELS}" \
    --timeout=3h30m \
    --v \
    --junit-report=junit_neuron_dra.xml \
    --output-dir="${ARTIFACT_DIR}" \
    ./tests/hw-accel/neuron/dra/...
