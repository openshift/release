#!/bin/bash
set -euo pipefail

SECRETS_DIR="/usr/local/ci-secrets/osp-ci-secrets"

if [ -s "${KUBECONFIG}" ]; then
    oc whoami
else
    (set +x; eval "$(cat "${SHARED_DIR}/api.login")")
fi

if [ -d "${SECRETS_DIR}" ]; then
    echo "Loading secrets from Vault (${SECRETS_DIR})..."
    for secret_file in "${SECRETS_DIR}"/*; do
        [ -f "${secret_file}" ] || continue
        key="$(basename "${secret_file}")"
        # Only export keys that look like valid env var names
        if [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            export "${key}=$(cat "${secret_file}")"
        fi
    done
    echo "Secrets loaded successfully"
else
    echo "WARNING: Secrets directory ${SECRETS_DIR} not found, tests requiring secrets may fail"
fi

echo "Waiting for TektonConfig CR to be ready..."
for i in $(seq 1 60); do
    READY=$(oc get tektonconfig config \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "${READY}" == "True" ]]; then
        echo "TektonConfig is ready after $((5*i)) seconds"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "ERROR: TektonConfig not ready within 5 minutes"
        echo "TektonConfig conditions:"
        oc get tektonconfig config \
            -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.message}){"\n"}{end}' 2>/dev/null || true
        exit 1
    fi
    sleep 5
done

echo "Running ginkgo tests with label filter: ${GINKGO_LABEL_FILTER}"

cd /tmp/release-tests-ginkgo

ginkgo run \
    --label-filter="${GINKGO_LABEL_FILTER}" \
    --timeout="${GINKGO_TIMEOUT}" \
    --junit-report="${ARTIFACT_DIR}/junit-report.xml" \
    -v \
    ./tests/...
