#!/bin/bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Read the namespace written by the reserve step
# ---------------------------------------------------------------------------
NS_FILE="${SHARED_DIR}/ephemeral-namespace"

if [[ ! -f "${NS_FILE}" ]]; then
    echo "No ephemeral-namespace file found in SHARED_DIR — nothing to release."
    exit 0
fi

NAMESPACE="$(cat "${NS_FILE}")"

if [[ -z "${NAMESPACE}" ]]; then
    echo "Ephemeral namespace file is empty — nothing to release."
    exit 0
fi

echo "Releasing ephemeral namespace: ${NAMESPACE}"

# ---------------------------------------------------------------------------
# Read ephemeral cluster credentials
# ---------------------------------------------------------------------------
CREDS_DIR="/usr/local/ci-secrets/ephemeral-cluster"

OC_LOGIN_TOKEN="$(cat "${CREDS_DIR}/oc-login-token")"
OC_LOGIN_SERVER="$(cat "${CREDS_DIR}/oc-login-server")"

# ---------------------------------------------------------------------------
# Install bonfire
# ---------------------------------------------------------------------------
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

python3 -m venv /tmp/bonfire-venv
# shellcheck source=/dev/null
source /tmp/bonfire-venv/bin/activate

python3 -m pip install --quiet --upgrade pip setuptools wheel
python3 -m pip install --quiet --upgrade "crc-bonfire${BONFIRE_VERSION}"

# ---------------------------------------------------------------------------
# Log in to the ephemeral cluster
# ---------------------------------------------------------------------------
EPH_KUBECONFIG="/tmp/ephemeral-release-kube/config"
mkdir -p "$(dirname "${EPH_KUBECONFIG}")"
export KUBECONFIG="${EPH_KUBECONFIG}"

set +x
oc login --token="${OC_LOGIN_TOKEN}" --server="${OC_LOGIN_SERVER}" --insecure-skip-tls-verify=true >/dev/null
set -x 2>/dev/null || true

# ---------------------------------------------------------------------------
# Release the namespace
# ---------------------------------------------------------------------------
export BONFIRE_BOT=true

bonfire namespace release "${NAMESPACE}" --force || {
    echo "WARNING: bonfire namespace release failed — attempting direct CR patch as fallback" >&2
    # Fallback: find the reservation CR and patch its duration to 0s
    RESERVATION=$(oc get namespacereservations -o json | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    if item.get('status', {}).get('namespace') == '${NAMESPACE}':
        print(item['metadata']['name'])
        break
" 2>/dev/null || true)

    if [[ -n "${RESERVATION}" ]]; then
        oc patch namespacereservation "${RESERVATION}" \
            --type=merge -p '{"spec":{"duration":"0s"}}' && \
            echo "Fallback release succeeded via CR patch." || \
            echo "WARNING: Fallback release also failed." >&2
    else
        echo "WARNING: Could not find reservation CR for namespace ${NAMESPACE}." >&2
    fi
}

echo "Namespace ${NAMESPACE} released."
