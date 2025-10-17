#!/bin/bash

set -e
set -u
set -o pipefail

PULL_SECRET=/var/run/secrets/ci.openshift.io/cluster-profile/pull-secret
TOOLS_DIR=/tmp/bin

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

function install_podman() {
    echo "Install podman"
    dnf install -y podman
}

function install_deps() {
    run_command "mkdir -p ${TOOLS_DIR}"
    run_command "export PATH=${TOOLS_DIR}:${PATH}"
    install_opm
    install_podman
}

function deploy_operators() {
    run_command "cd $(mktemp -d)"
    run_command "git clone --depth 1 https://github.com/ajaggapa/deploy-konflux-operator.git"
    run_command "chmod -R a+x deploy-konflux-operator"
    run_command "deploy-konflux-operator/deploy-operator.sh --operator ${DEPLOY_KONFLUX_OPERATORS} --quay-auth ${PULL_SECRET}"
}

set_proxy
run_command "oc whoami"
run_command "which oc && oc version -o yaml"
install_deps
deploy_operators



