#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

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

echo "Upgrade target is ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
export TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
export TARGET_VERSION

retry=5
while (( retry > 0 )); do
    unrecommened_conditional_updates=$(oc get clusterversion version -o json | jq -r '.status.conditionalUpdates[]? | select((.conditions[].type == "Recommended") and (.conditions[].status != "True")) | .release.version' | xargs)
    if [[ -z "${unrecommened_conditional_updates}" ]]; then
        retry=$((retry - 1))
        sleep 60
        echo "No conditionalUpdates update available! Retry..."
    else
        #shellcheck disable=SC2076
        if [[ " $unrecommened_conditional_updates " =~ " $TARGET_VERSION " ]]; then
            echo "Error: $TARGET_VERSION is not recommended, for details please refer:"
            oc get clusterversion version -o json | jq -r '.status.conditionalUpdates[]? | select((.conditions[].type == "Recommended") and (.conditions[].status != "True"))'
            exit 1
        fi
        break
    fi
done
