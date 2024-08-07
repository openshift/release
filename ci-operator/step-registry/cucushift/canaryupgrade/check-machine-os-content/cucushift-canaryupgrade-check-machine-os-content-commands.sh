#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function get_machine_os_content() {
    local payload="$1"
    oc adm release info ${payload} --image-for machine-os-content


    oc adm release info quay.io/openshift-release-dev/ocp-release@sha256:eeaf087727b4ec3fa36bf2b1e812e48682f0415b9d2d53be83704931172a856c --image-for machine-os-content
}

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

pause
