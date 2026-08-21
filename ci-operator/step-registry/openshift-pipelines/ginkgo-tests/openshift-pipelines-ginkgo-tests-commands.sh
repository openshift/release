#!/bin/bash
set -euo pipefail

SECRETS_DIR="/usr/local/ci-secrets/osp-ci-secrets"

ALLOWED_SECRETS=(
    GITHUB_TOKEN
    PAC_GITHUB_TOKEN
    PAC_GITHUB_ORG
    PAC_GITHUB_WEBHOOK_TOKEN
    GITLAB_TOKEN
    GITLAB_GROUP_NAMESPACE
    GITLAB_PROJECT_ID
    GITLAB_WEBHOOK_TOKEN
    QUAY_USER
    QUAY_PASS
    QUAY_API_TOKEN
    CHAINS_REPOSITORY
    CHAINS_DOCKER_CONFIG_JSON
    JIB_MAVEN_REPOSITORY
    JIB_MAVEN_DOCKER_CONFIG_JSON
)

if [ -s "${KUBECONFIG}" ]; then
    oc whoami
else
    login_file="${SHARED_DIR}/api.login"
    if [[ ! -r "${login_file}" ]]; then
        echo "ERROR: ${login_file} not found or not readable"
        exit 1
    fi
    set +x
    login_cmd="$(cat "${login_file}")"
    eval "${login_cmd}"
fi

if [ -d "${SECRETS_DIR}" ]; then
    echo "Loading allowed secrets from Vault (${SECRETS_DIR})..."
    loaded=0
    for key in "${ALLOWED_SECRETS[@]}"; do
        secret_file="${SECRETS_DIR}/${key}"
        [ -f "${secret_file}" ] || continue
        secret_value="$(cat "${secret_file}")" || {
            echo "ERROR: Failed to read secret file for ${key}"
            exit 1
        }
        export "${key}=${secret_value}"
        loaded=$((loaded + 1))
    done
    echo "Loaded ${loaded}/${#ALLOWED_SECRETS[@]} secrets"
else
    echo "WARNING: Secrets directory ${SECRETS_DIR} not found, tests requiring secrets may fail"
fi

echo "Waiting for TektonConfig CR to be ready..."
for i in $(seq 1 60); do
    READY=$(oc --request-timeout=12s get tektonconfig config \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "${READY}" == "True" ]]; then
        echo "TektonConfig is ready after $((5*i)) seconds"
        break
    fi
    if [[ $i -eq 60 ]]; then
        echo "ERROR: TektonConfig not ready within 5 minutes"
        echo "TektonConfig conditions:"
        oc --request-timeout=12s get tektonconfig config \
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
