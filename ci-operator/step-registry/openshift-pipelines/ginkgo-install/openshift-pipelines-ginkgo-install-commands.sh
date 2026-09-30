#!/bin/bash
set -euo pipefail

SECRETS_DIR="/usr/local/ci-secrets/osp-ci-secrets"

# login for interop
if [ -s "${KUBECONFIG:-}" ]; then
    oc whoami
else # login for ROSA & Hypershift platforms
    login_file="${SHARED_DIR}/api.login"
    if [[ ! -r "${login_file}" ]]; then
        echo "ERROR: ${login_file} not found or not readable"
        exit 1
    fi
    # Disable tracing due to credential handling
    (set +x; eval "$(cat "${login_file}")")
fi

# Load Vault secrets (some install specs may require them)
if [ -d "${SECRETS_DIR}" ]; then
    echo "Loading secrets from Vault (${SECRETS_DIR})..."
    loaded=0
    for f in "${SECRETS_DIR}"/*; do
        [ -f "$f" ] || continue
        key="$(basename "$f")"
        var="${key//[^A-Za-z0-9_]/_}"
        # Env vars cannot start with a digit; prefix with underscore if needed.
        [[ "$var" =~ ^[0-9] ]] && var="_${var}"
        export "${var}=$(cat "$f")"
        loaded=$((loaded + 1))
    done
    echo "Loaded ${loaded} secrets"
fi

echo "Installing openshift-pipelines operator via Ginkgo (path: ${GINKGO_TEST_PATH}, label filter: ${GINKGO_LABEL_FILTER})"

cd /tmp/release-tests-ginkgo

CONSOLE_URL="$(oc whoami --show-console)" \
    API_URL="$(oc whoami --show-server)" \
    CATALOG_SOURCE="${CATALOG_SOURCE:-redhat-operators}" \
    CHANNEL="${OLM_CHANNEL:-latest}" \
    ginkgo run \
        --label-filter="${GINKGO_LABEL_FILTER}" \
        --timeout="${GINKGO_TIMEOUT}" \
        --junit-report="${ARTIFACT_DIR}/junit-openshift-pipelines-ginkgo-install.xml" \
        -v \
        "${GINKGO_TEST_PATH}"
