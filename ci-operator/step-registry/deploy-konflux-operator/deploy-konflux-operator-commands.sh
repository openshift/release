#!/bin/bash

set -e
set -u
set -o pipefail

declare -r PULL_SECRET=/var/run/vault/deploy-konflux-operator-art-image-share
declare -r TOOLS_DIR=/tmp/bin
declare -r MIRROR_REGISTRY_DIR="${MIRROR_REGISTRY_DIR:-"/var/run/vault/mirror-registry"}"
declare -r MIRROR_REGISTRY_CREDS="${MIRROR_REGISTRY_DIR}/registry_creds"
declare -r DEPLOY_KONFLUX_OPERATOR_VERSION=v7.1

if [[ -n "${KONFLUX_TARGET_OPERATORS:-}" && -n "${KONFLUX_TARGET_FBC_TAGS:-}" ]]; then
    echo "ERROR: KONFLUX_TARGET_OPERATORS and KONFLUX_TARGET_FBC_TAGS cannot be set at the same time"
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

function install_opm() {
    echo "Install opm"
    run_command "curl -L --retry 5 https://github.com/operator-framework/operator-registry/releases/download/v1.26.2/linux-amd64-opm -o ${TOOLS_DIR}/opm && chmod +x ${TOOLS_DIR}/opm"
}

function install_oc() {
    echo "Install oc"
    run_command "curl -L --retry 5 https://mirror.openshift.com/pub/openshift-v4/multi/clients/ocp/stable/$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/;')/openshift-client-linux.tar.gz | tar -xz -C ${TOOLS_DIR} oc && chmod +x ${TOOLS_DIR}/oc"
}

function install_deps() {
    run_command "mkdir -p ${TOOLS_DIR}"
    run_command "export PATH=${TOOLS_DIR}:${PATH}"
    install_opm
    install_oc # we need a modern client
}

function deploy_operators() {
    run_command "cd $(mktemp -d)"
    run_command "git clone --depth 1 --branch registry_proxy https://github.com/mgencur/deploy-konflux-operator.git"
    run_command "chmod -R a+x deploy-konflux-operator"

    declare args=()
    if [[ -n "${KONFLUX_TARGET_OPERATORS:-}" ]]; then
        args+=(--operator "${KONFLUX_TARGET_OPERATORS}")
    fi
    if [[ -n "${KONFLUX_TARGET_FBC_TAGS:-}" ]]; then
        args+=(--fbc-tag "${KONFLUX_TARGET_FBC_TAGS}")
    fi

    if [[ "${DISCONNECTED:-false}" == "true" ]]; then
        local mirror_registry_url
        mirror_registry_url=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        local mirror_registry_proxy_url
        mirror_registry_proxy_url="${mirror_registry_url//5000/6001}"
        local registry_creds
        registry_creds=$(head -n 1 "${MIRROR_REGISTRY_CREDS}" | base64 -w 0)
        local registry_auth
        registry_auth=$(mktemp)
        cat <<EOF > "${registry_auth}"
{
    "auths": {
        "${mirror_registry_url}": {
            "auth": "${registry_creds}"
        }
    }
}
EOF
        local registry_proxy_auth
        registry_proxy_auth=$(mktemp)
        cat <<EOF > "${registry_proxy_auth}"
{
    "auths": {
        "${mirror_registry_proxy_url}": {
            "auth": "${registry_creds}"
        }
    }
}
EOF
        if [[ "${USE_REGISTRY_PROXY:-false}" == "true" ]]; then
            args+=(--internal-registry-proxy "${mirror_registry_proxy_url}" --internal-registry-proxy-auth "${registry_proxy_auth}")
        else
            args+=(--internal-registry "${mirror_registry_url}" --internal-registry-auth "${registry_auth}" --quay-auth "${PULL_SECRET}/.dockerconfigjson")
        fi
    else
        args+=(--quay-auth "${PULL_SECRET}/.dockerconfigjson")
    fi

    run_command "oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > ${SHARED_DIR}/old_dockerconfigjson"

    run_command "deploy-konflux-operator/deploy-operator.sh ${args[*]}"
}

set_proxy
install_deps
run_command "oc whoami"
run_command "which oc && oc version -o yaml"
deploy_operators
