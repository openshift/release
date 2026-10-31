#!/bin/bash

set -e
set -u
set -o pipefail

declare -r PULL_SECRET=/var/run/vault/deploy-konflux-operator-art-image-share
declare -r TOOLS_DIR=/tmp/bin
declare -r MIRROR_REGISTRY_DIR="${MIRROR_REGISTRY_DIR:-"/var/run/vault/mirror-registry"}"
declare -r MIRROR_REGISTRY_CREDS="${MIRROR_REGISTRY_DIR}/registry_creds"
declare -r USE_REGISTRY_PROXY="${KONFLUX_USE_REGISTRY_PROXY:-false}"
declare -r REGISTRY_PROXY_HOST="${KONFLUX_REGISTRY_PROXY_HOST:-""}"
declare -r REGISTRY_PROXY_PORT="${KONFLUX_REGISTRY_PROXY_PORT:-""}"
declare -r DEPLOY_KONFLUX_OPERATOR_VERSION=v8.1

if [[ -n "${KONFLUX_TARGET_OPERATORS:-}" && -n "${KONFLUX_TARGET_FBC_TAGS:-}" ]]; then
    echo "ERROR: KONFLUX_TARGET_OPERATORS and KONFLUX_TARGET_FBC_TAGS cannot be set at the same time"
    exit 1
fi

if [[ -n "${REGISTRY_PROXY_HOST:-}" && -z "${REGISTRY_PROXY_PORT:-}" ]]; then
    echo "ERROR: KONFLUX_REGISTRY_PROXY_PORT is required when KONFLUX_REGISTRY_PROXY_HOST is set"
    exit 1
fi

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function create_registry_auth() {
    local registry_url="$1"
    local auth_creds="$2"
    local auth_file
    auth_file=$(mktemp)
    cat <<EOF > "${auth_file}"
{
    "auths": {
        "${registry_url}": {
            "auth": "${auth_creds}"
        }
    }
}
EOF
    echo "${auth_file}"
}

function install_opm() {
    echo "Install opm"
    run_command "curl -L --retry 5 https://github.com/operator-framework/operator-registry/releases/download/v1.26.2/linux-amd64-opm -o ${TOOLS_DIR}/opm && chmod +x ${TOOLS_DIR}/opm"
}

function install_oc() {
    echo "Install oc"
    run_command "curl -L --retry 5 https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/multi/clients/ocp/stable/$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/;')/openshift-client-linux.tar.gz | tar -xz -C ${TOOLS_DIR} oc && chmod +x ${TOOLS_DIR}/oc"
}

function install_deps() {
    run_command "mkdir -p ${TOOLS_DIR}"
    run_command "export PATH=${TOOLS_DIR}:${PATH}"
    install_opm
    install_oc # we need a modern client
}

# Restore the saved OperatorHub setting and wait for redhat-operators when enabled.
# Takes the original OperatorHub JSON; returns nonzero on restoration or readiness failure.
function restore_default_catalogs() {
    local operatorhub_config="$1"
    local patch
    patch=$(jq -c '{spec: {disableAllDefaultSources: .spec.disableAllDefaultSources}}' <<< "${operatorhub_config}") || return 1

    echo "Restoring the original OperatorHub default catalog configuration"
    oc patch operatorhub cluster --type=merge -p "${patch}" --request-timeout=30s || return 1

    # Per-source settings take precedence over disableAllDefaultSources.
    if ! jq -e '([.spec.sources[]? | select(.name == "redhat-operators")] | first) as $source |
        if $source != null then $source.disabled != true
        else .spec.disableAllDefaultSources != true end' \
        <<< "${operatorhub_config}" >/dev/null; then
        return 0
    fi

    echo "Waiting for the redhat-operators catalog to be ready"
    local deadline=$((SECONDS + 300))
    local state
    while (( SECONDS < deadline )); do
        if state=$(oc get catalogsource redhat-operators -n openshift-marketplace \
            -o jsonpath='{.status.connectionState.lastObservedState}' --request-timeout=30s) && [[ "${state}" == READY ]]; then
            return 0
        fi
        sleep 5
    done
    echo "ERROR: redhat-operators catalog was not ready within 300 seconds"
    return 1
}

# Run the Konflux helper and optionally restore catalogs, preserving deployment failures.
function deploy_operators() {
    run_command "cd $(mktemp -d)"
    run_command "git clone --depth 1 --branch ${DEPLOY_KONFLUX_OPERATOR_VERSION} https://github.com/ajaggapa/deploy-konflux-operator.git"
    run_command "chmod -R a+x deploy-konflux-operator"

    declare args=()
    if [[ -n "${KONFLUX_TARGET_OPERATORS:-}" ]]; then
        args+=(--operator "${KONFLUX_TARGET_OPERATORS}")
    fi
    if [[ -n "${KONFLUX_TARGET_FBC_TAGS:-}" ]]; then
        args+=(--fbc-tag "${KONFLUX_TARGET_FBC_TAGS}")
    fi

    local mirror_registry_creds
    mirror_registry_creds=$(head -n 1 "${MIRROR_REGISTRY_CREDS}" | base64 -w 0)

    if [[ "${DISCONNECTED:-false}" == "true" ]]; then
        local mirror_registry_url
        mirror_registry_url=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")

        # Configure registry proxy if enabled
        if [[ "${USE_REGISTRY_PROXY:-false}" == "true" ]]; then
            # Set proxy port (default: 6003)
            local registry_proxy_port="${REGISTRY_PROXY_PORT:-6003}"
            local registry_proxy_url

            # Determine proxy URL: use explicit host if provided, otherwise derive from mirror registry
            if [[ -n "${REGISTRY_PROXY_HOST:-}" ]]; then
                # Use explicitly provided proxy host and port
                registry_proxy_url="${REGISTRY_PROXY_HOST}:${REGISTRY_PROXY_PORT}"
            else
                # Derive proxy URL from mirror registry by replacing port 5000 with proxy port.
                # This is for cases where registry proxy is derived from mirror registry url,
                # but just running on a different port.
                registry_proxy_url="${mirror_registry_url//5000/${registry_proxy_port}}"
            fi

            local registry_proxy_auth
            registry_proxy_auth=$(create_registry_auth "${registry_proxy_url}" "${mirror_registry_creds}")
            args+=(--internal-registry-proxy "${registry_proxy_url}" --internal-registry-proxy-auth "${registry_proxy_auth}")
        else
            local registry_auth
            registry_auth=$(create_registry_auth "${mirror_registry_url}" "${mirror_registry_creds}")
            args+=(--internal-registry "${mirror_registry_url}" --internal-registry-auth "${registry_auth}" --quay-auth "${PULL_SECRET}/.dockerconfigjson")
        fi
    else
        args+=(--quay-auth "${PULL_SECRET}/.dockerconfigjson")
    fi

    local operatorhub_config=""
    if [[ "${KONFLUX_RESTORE_DEFAULT_CATALOGS:-false}" == true && "${KONFLUX_DEPLOY_OPERATORS:-true}" != false ]]; then
        operatorhub_config=$(oc get operatorhub cluster -o json --request-timeout=30s)
    fi

    local deploy_status=0
    run_command "deploy-konflux-operator/deploy-operator.sh ${args[*]}" || deploy_status=$?

    # Restore catalogs even when the helper fails, preserving its failure status.
    if [[ -n "${operatorhub_config}" ]]; then
        restore_default_catalogs "${operatorhub_config}" || {
            echo "ERROR: Failed to restore default catalogs"
            if (( deploy_status == 0 )); then
                deploy_status=1
            fi
        }
    fi
    return "${deploy_status}"
}

set_proxy
install_deps
run_command "oc whoami"
run_command "which oc && oc version -o yaml"
deploy_operators
