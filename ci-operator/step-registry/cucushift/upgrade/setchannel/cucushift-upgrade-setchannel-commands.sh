#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login

valid_channels=("fast" "stable" "candidate" "eus")
valid_channel="false"
for channel in "${valid_channels[@]}"; do
    if [[ "${UPGRADE_CHANNEL}" == "${channel}" ]]; then
        valid_channel="true" 
        break
    fi
done
if [[ "${valid_channel}" == "false" ]]; then
    echo "Specified channel ${UPGRADE_CHANNEL} is not valid, upgrade will not start due to fail to set correct channel!"
    exit 1
fi

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# oc cli is injected from release:target
run_command "which oc"
run_command "oc version --client"

export DUMMY_TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
DUMMY_TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${DUMMY_TARGET}" --output=json | jq -r '.metadata.version')"
echo "Target version of ci config is: ${DUMMY_TARGET_VERSION}"
x_ver=$( echo "${DUMMY_TARGET_VERSION}" | cut -f1 -d. )
y_ver=$( echo "${DUMMY_TARGET_VERSION}" | cut -f2 -d. )
ver="${x_ver}.${y_ver}"
target_channel="${UPGRADE_CHANNEL}-${ver}"
if ! oc adm upgrade channel ${target_channel}; then
    echo "Fail to change channel to ${target_channel}!"
    exit 1
fi

