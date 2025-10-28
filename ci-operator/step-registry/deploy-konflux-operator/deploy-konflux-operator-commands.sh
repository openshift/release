#!/bin/bash

set -e
set -u
set -o pipefail

PULL_SECRET=/var/run/vault/deploy-konflux-operator-art-image-share
TOOLS_DIR=/tmp/bin
DEPLOY_KONFLUX_OPERATOR_VERSION=v5.0

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

function install_deps() {
    run_command "mkdir -p ${TOOLS_DIR}"
    run_command "export PATH=${TOOLS_DIR}:${PATH}"
    install_opm
}

function install_secret() {
    local current_pull_secret_dir current_pull_secret add_pull_secret new_pull_secret
    current_pull_secret_dir=$(mktemp -d)
    current_pull_secret=${current_pull_secret_dir}/.dockerconfigjson
    add_pull_secret=${PULL_SECRET}/.dockerconfigjson
    new_pull_secret=$(mktemp)
    run_command "oc extract secret/pull-secret -n openshift-config --confirm --to ${current_pull_secret_dir}"
    run_command "jq -s '{\"auths\": (.[0].auths + .[1].auths)}' ${current_pull_secret} ${add_pull_secret} > ${new_pull_secret}"
    run_command "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_pull_secret}"
    run_command "shred ${current_pull_secret} ${new_pull_secret}"
}

function deploy_operators() {
    run_command "cd $(mktemp -d)"
    run_command "git clone --depth 1 --branch ${DEPLOY_KONFLUX_OPERATOR_VERSION} https://github.com/ajaggapa/deploy-konflux-operator.git"
    run_command "chmod -R a+x deploy-konflux-operator"
    run_command "deploy-konflux-operator/deploy-operator.sh --operator ${DEPLOY_KONFLUX_OPERATORS}"
}

set_proxy
run_command "oc whoami"
run_command "which oc && oc version -o yaml"
install_deps
install_secret
deploy_operators
