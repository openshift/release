#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login

# Extract oc binary which is supposed to be identical with target release
function extract_oc(){
    echo -e "Extracting oc\n"
    local retry=5 tmp_oc="/tmp/client-2"
    mkdir -p ${tmp_oc}
    while ! (env "NO_PROXY=*" "no_proxy=*" oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --command=oc --to=${tmp_oc} ${DUMMY_TARGET});
    do
        echo >&2 "Failed to extract oc binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_oc}/oc ${OC_DIR} -f
    which oc
    oc version --client
    return 0
}

valid_channels=("fast" "stable" "candidate" "eus")
valid_channel="false"
for channel in ${valid_channels[*]}; do
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

mkdir -p /tmp/client
export OC_DIR="/tmp/client"
export PATH=${OC_DIR}:$PATH
export DUMMY_TARGET="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"
# we need this DUMMY_TARGET_VERSION from ci config to download oc
DUMMY_TARGET_VERSION="$(env "NO_PROXY=*" "no_proxy=*" oc adm release info "${DUMMY_TARGET}" --output=json | jq -r '.metadata.version')"
echo "Target version of ci config is: ${DUMMY_TARGET_VERSION}"
extract_oc

x_ver=$( echo "${DUMMY_TARGET_VERSION}" | cut -f1 -d. )
y_ver=$( echo "${DUMMY_TARGET_VERSION}" | cut -f2 -d. )
ver="${x_ver}.${y_ver}"
target_channel="${UPGRADE_CHANNEL}-${ver}"
if ! oc adm upgrade channel ${target_channel}; then
    echo "Fail to change channel to ${target_channel}!"
    exit 1
fi
retry=3
while (( retry > 0 ));do
    recommends=$(oc get clusterversion version -o json|jq -r '.status.availableUpdates[]?.version'| xargs)
    if [[ "${recommends}" == "null" ]] || [[ "${recommends}" != *"${ver}"* ]]; then
        (( retry -= 1 ))
        sleep 60
        echo "No recommended update available! Retry..."
    else
        echo "Recommencded update: ${recommends}"
        break
    fi
done
if (( retry == 0 )); then
    echo "Timeout to get recommended update!" 
    exit 1
fi

