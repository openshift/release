#!/bin/bash

set -euo pipefail

trap 'echo "ERROR: ephemeral-namespace-reserve step failed" >&2' ERR

# ---------------------------------------------------------------------------
# Read ephemeral cluster credentials (mounted from Vault secret)
# ---------------------------------------------------------------------------
CREDS_DIR="/usr/local/ci-secrets/ephemeral-cluster"

OC_LOGIN_TOKEN="$(cat "${CREDS_DIR}/oc-login-token")"
OC_LOGIN_SERVER="$(cat "${CREDS_DIR}/oc-login-server")"

# ---------------------------------------------------------------------------
# Install bonfire into a virtual-env
# ---------------------------------------------------------------------------
echo "Installing bonfire (crc-bonfire${BONFIRE_VERSION})..."

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

python3 -m venv /tmp/bonfire-venv
# shellcheck source=/dev/null
source /tmp/bonfire-venv/bin/activate

python3 -m pip install --quiet --upgrade pip setuptools wheel
python3 -m pip install --quiet --upgrade "crc-bonfire${BONFIRE_VERSION}"

echo "Installed bonfire $(bonfire --version 2>/dev/null || echo 'unknown version')"

# ---------------------------------------------------------------------------
# Set up a separate kubeconfig so we do not clobber the CI-provided one
# ---------------------------------------------------------------------------
EPH_KUBECONFIG_DIR="/tmp/ephemeral-kube"
EPH_KUBECONFIG="${EPH_KUBECONFIG_DIR}/config"
rm -rf "${EPH_KUBECONFIG_DIR}"
mkdir -p "${EPH_KUBECONFIG_DIR}"
export KUBECONFIG="${EPH_KUBECONFIG}"

# Disable tracing around login to avoid leaking the token
echo "Logging in to ephemeral cluster at ${OC_LOGIN_SERVER}..."
set +x
oc login --token="${OC_LOGIN_TOKEN}" --server="${OC_LOGIN_SERVER}" --insecure-skip-tls-verify=true >/dev/null
set -x 2>/dev/null || true

echo "Logged in as $(oc whoami)"

# ---------------------------------------------------------------------------
# Reserve the namespace via bonfire
# ---------------------------------------------------------------------------
REQUESTER="${BONFIRE_NAMESPACE_REQUESTER}"
if [[ -z "${REQUESTER}" ]]; then
    REQUESTER="${JOB_NAME:-openshift-ci}"
fi

export BONFIRE_BOT=true
export BONFIRE_NS_REQUESTER="${REQUESTER}"

echo "Reserving namespace (pool=${BONFIRE_NAMESPACE_POOL}, duration=${BONFIRE_NAMESPACE_DURATION}, timeout=${BONFIRE_NAMESPACE_TIMEOUT}s)..."

NAMESPACE=$(bonfire namespace reserve \
    --pool "${BONFIRE_NAMESPACE_POOL}" \
    --duration "${BONFIRE_NAMESPACE_DURATION}" \
    --timeout "${BONFIRE_NAMESPACE_TIMEOUT}" \
    --force)

if [[ -z "${NAMESPACE}" ]]; then
    echo "ERROR: bonfire returned an empty namespace" >&2
    exit 1
fi

echo "Reserved namespace: ${NAMESPACE}"

# Switch to the reserved namespace
oc project "${NAMESPACE}"

# ---------------------------------------------------------------------------
# Write outputs to SHARED_DIR for downstream steps
# ---------------------------------------------------------------------------
echo -n "${NAMESPACE}" > "${SHARED_DIR}/ephemeral-namespace"
cp "${EPH_KUBECONFIG}" "${SHARED_DIR}/ephemeral-kubeconfig"
echo -n "${OC_LOGIN_SERVER}" > "${SHARED_DIR}/ephemeral-cluster-server"

echo "Namespace reservation complete. Outputs written to SHARED_DIR."
echo "  ephemeral-namespace:      ${NAMESPACE}"
echo "  ephemeral-kubeconfig:     ${SHARED_DIR}/ephemeral-kubeconfig"
echo "  ephemeral-cluster-server: ${OC_LOGIN_SERVER}"
