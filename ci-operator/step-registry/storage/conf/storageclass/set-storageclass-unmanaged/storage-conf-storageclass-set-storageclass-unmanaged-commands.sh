#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
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

function set_sc_state_unmanaged () {
    run_command "oc patch clustercsidriver $(oc get sc "${REQUIRED_UNMANAGED_STORAGECLASS}" -ojsonpath='{.provisioner}') -p '[{\"op\":\"replace\",\"path\":\"/spec/storageClassState\",\"value\":\"Unmanaged\"}]' --type json"
}

set_proxy
set_sc_state_unmanaged
