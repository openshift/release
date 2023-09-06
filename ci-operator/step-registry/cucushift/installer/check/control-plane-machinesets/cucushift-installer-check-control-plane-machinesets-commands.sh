#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
KUBECONFIG="" oc registry login

# check if controlplanemachinesets is supported by the IaaS and the OCP version
# return 0 if controlplanemachinesets is supported, otherwise 1
function hasCPMS() {
    ret=1

    case "${CLUSTER_TYPE}" in
    aws*)
        # 4.12+
        REQUIRED_OCP_VERSION="4.12"
        ;;
    azure*)
        # 4.13+
        REQUIRED_OCP_VERSION="4.13"
        ;;
    gcp)
        # 4.13+
        REQUIRED_OCP_VERSION="4.13"
        ;;
    nutanix)
        # 4.14+
        REQUIRED_OCP_VERSION="4.14"
        ;;
    *)
        return ${ret}
        ;;
    esac    

    version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
    echo "OCP version: ${version}"
    if [ -n "${version}" ] && [ "$(printf '%s\n' "${REQUIRED_OCP_VERSION}" "${version}" | sort --version-sort | head -n1)" = "${REQUIRED_OCP_VERSION}" ]; then
        ret=0
    fi
    return ${ret}
}

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if ! hasCPMS; then
    echo "INFO: 'controlplanemachinesets' is not supproted (OCP $(getVersion) on ${CLUSTER_TYPE}), skip checking"
    exit 0
fi

# control-plane machinesets
stderr=$(mktemp)
stdout=$(mktemp)
oc get controlplanemachinesets -n openshift-machine-api --no-headers 1>${stdout} 2>${stderr} || true

curr_state=$(grep cluster ${stdout} | awk '{print $6}' || true)
if [[ "${curr_state}" != "${EXPECTED_CPMS_STATE}" ]]; then
    echo "ERROR: Unexpected controlplanemachinesets state '${curr_state}'."
    echo -e "\n------ STANDARD OUT ------\n$(cat ${stdout})\n------ STANDARD ERROR ------\n$(cat ${stderr})\n"
    exit 1
else
    echo "INFO: controlplanemachinesets does be ${EXPECTED_CPMS_STATE}."
fi

echo "control-plane machinesets:"
cat "${stdout}"
