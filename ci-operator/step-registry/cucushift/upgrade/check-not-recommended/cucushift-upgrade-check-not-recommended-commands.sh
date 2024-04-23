#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


# Extract oc binary which is supposed to be identical with target release
function extract_oc(){
    echo -e "Extracting oc\n"
    local retry=5 tmp_oc="/tmp/client-2"
    mkdir -p ${tmp_oc}
    while ! (env "NO_PROXY=*" "no_proxy=*" oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --command=oc --to=${tmp_oc} ${TARGET});
    do
        echo >&2 "Failed to extract oc binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_oc}/oc ${OC_DIR} -f
    export PATH="$PATH"
    which oc
    oc version --client
    return 0
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Target version oc will be extract in the /tmp/client directory, use it first
mkdir -p /tmp/client
export OC_DIR="/tmp/client"
export PATH=${OC_DIR}:$PATH

echo "Upgrade target is ${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
export TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${TARGET}" --output=json | jq -r '.metadata.version')"
extract_oc

retry=3
while (( retry > 0 )); do
    conditional_updates=$(oc get clusterversion version -o json | jq -r '.status.conditionalUpdates[]? | select (.conditions[].status!="True")| .release.version' | xargs)
    if [[ -z "${conditional_updates}" ]]; then
        retry=$((retry - 1))
        sleep 60
        echo "No conditionalUpdates update available! Retry..."
    else
        #shellcheck disable=SC2076
        if [[ " $conditional_updates " =~ " $TARGET_VERSION " ]]; then
            echo "Error: $TARGET_VERSION is not recommended, for details please refer:"
            oc get clusterversion version -o json | jq -r '.status.conditionalUpdates[]? | select (.conditions[].status!="True")'
            exit 1
        fi
        break
    fi
done
