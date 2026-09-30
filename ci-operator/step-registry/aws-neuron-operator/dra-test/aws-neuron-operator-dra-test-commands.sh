#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

echo "Starting AWS Neuron DRA E2E tests"

TOOLS_DIR=$(mktemp -d /tmp/neuron-dra-tools.XXXXXX)
DOWNLOAD_DIR=$(mktemp -d /tmp/neuron-dra-downloads.XXXXXX)
trap 'rm -rf "${TOOLS_DIR}" "${DOWNLOAD_DIR}"' EXIT
mkdir -p "${ARTIFACT_DIR}"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if ! command -v oc &>/dev/null; then
    OC_VERSION="4.21.0"
    OC_ARCHIVE="${DOWNLOAD_DIR}/openshift-client-linux.tar.gz"
    OC_SHA256="735b43f9ae4ffe8f1777b13e23d691540f51dcbe18ac73ab058754d42abfb4b2"
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error --retry 3 \
        "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" \
        --output "${OC_ARCHIVE}"
    printf '%s  %s\n' "${OC_SHA256}" "${OC_ARCHIVE}" | sha256sum --check --status
    tar xzf "${OC_ARCHIVE}" -C "${DOWNLOAD_DIR}" oc
    install -m 0755 "${DOWNLOAD_DIR}/oc" "${TOOLS_DIR}/oc"
fi

if ! command -v jq &>/dev/null; then
    JQ_VERSION="1.7.1"
    JQ_BINARY="${DOWNLOAD_DIR}/jq-linux-amd64"
    JQ_SHA256="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
    curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error --retry 3 \
        "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64" \
        --output "${JQ_BINARY}"
    printf '%s  %s\n' "${JQ_SHA256}" "${JQ_BINARY}" | sha256sum --check --status
    install -m 0755 "${JQ_BINARY}" "${TOOLS_DIR}/jq"
fi

# TOOLS_DIR is fresh and contains only binaries that passed pinned SHA-256
# verification. Do not expose it to command lookup before this point.
export PATH="${TOOLS_DIR}:${PATH}"

if [[ -f "${SHARED_DIR}/neuron-deviceconfig.env" ]]; then
    source "${SHARED_DIR}/neuron-deviceconfig.env"
fi

# KMM needs a registry credential to push the in-cluster-built kernel image and
# for the generated module loader to pull that image back from the internal
# registry.  The builder service account is present in every OpenShift
# namespace and is granted system:image-builder by default.  Use a fresh
# short-lived token when the job did not provide an explicit secret name.
NEURON_NAMESPACE="aws-neuron-operator"
if [[ -n "${ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET:-}" ]]; then
    if ! oc -n "${NEURON_NAMESPACE}" get secret "${ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET}" >/dev/null 2>&1; then
        echo "ERROR: ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET=${ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET} does not exist in ${NEURON_NAMESPACE}" >&2
        exit 1
    fi
    echo "Using configured Neuron image repository secret ${ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET}"
elif [[ -n "${ECO_HWACCEL_NEURON_DRA_DRIVER_IMAGE:-}" && -n "${ECO_HWACCEL_NEURON_DRIVER_VERSION:-}" ]]; then
    ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET="neuron-build-push-secret"
    export ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET

    oc -n "${NEURON_NAMESPACE}" policy add-role-to-user \
        system:image-builder "system:serviceaccount:${NEURON_NAMESPACE}:builder" >/dev/null
    BUILDER_TOKEN=$(oc -n "${NEURON_NAMESPACE}" create token builder --duration=24h)
    oc -n "${NEURON_NAMESPACE}" delete secret "${ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET}" \
        --ignore-not-found >/dev/null
    oc -n "${NEURON_NAMESPACE}" create secret docker-registry \
        "${ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET}" \
        --docker-server=image-registry.openshift-image-registry.svc:5000 \
        --docker-username=builder \
        --docker-password="${BUILDER_TOKEN}" \
        --dry-run=client -o yaml | oc apply -f - >/dev/null
    unset BUILDER_TOKEN
    echo "Created short-lived Neuron image repository secret ${ECO_HWACCEL_NEURON_IMAGE_REPO_SECRET}"
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
