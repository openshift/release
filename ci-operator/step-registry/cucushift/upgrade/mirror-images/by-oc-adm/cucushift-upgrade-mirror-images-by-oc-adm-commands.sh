#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

function set_proxy_env(){
    # Setup proxy if it's present in the shared dir
    if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
        # shellcheck disable=SC1091
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
}

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response
    digest="$(echo "${TARGET}" | cut -f2 -d@)"
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    response=$(curl --silent --output /dev/null --write-out %"{http_code}" "https://mirror2.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
    if (( response == 200 )); then
        echo "${TARGET} is signed" && return 0
    else
        echo "Seem like ${TARGET} is not signed" && return 1
    fi
}

function mirror_image(){
    local mirror_release_image target_version cmd
    mirror_release_image="${MIRROR_REGISTRY_HOST}/${TARGET#*/}"
    MIRROR_RELEASE_IMAGE_REPO="${mirror_release_image%:*}"
    MIRROR_RELEASE_IMAGE_REPO="${MIRROR_RELEASE_IMAGE_REPO%@sha256*}"
    export MIRROR_RELEASE_IMAGE_REPO

    target_version=$(oc adm release info "${TARGET}" --output=json | jq .metadata.version)
   
    echo "Mirroring ${target_version} (${TARGET}) to ${MIRROR_RELEASE_IMAGE_REPO}"

    cmd="oc adm release mirror -a ${PULL_SECRET} --insecure=true --from=${TARGET} --to=${MIRROR_RELEASE_IMAGE_REPO}"
    if [[ "${APPLY_SIG}" == "true" ]]; then
        cmd="${cmd} --release-image-signature-to-dir=${SAVE_SIG_TO_DIR}"
    fi
    run_command "${cmd} | tee ${MIRROR_OUT_FILE}"
}

function apply_signature(){
    if [[ "${APPLY_SIG}" == "true" ]]; then
        echo "Apply signature against cluster..."
        run_command "oc apply -f ${SAVE_SIG_TO_DIR}/signature-*.json --overwrite=true"
    fi
}

function update_icsp(){
    local source_release_image_repo
    source_release_image_repo="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE%:*}"
    source_release_image_repo="${source_release_image_repo%@sha256*}"
    if [[ "${source_release_image_repo}" != "${MIRROR_RELEASE_IMAGE_REPO}" ]] && ! oc get ImageContentSourcePolicy example -oyaml; then
        echo "Target image has different repo with source image and icsp example is not present, creating icsp"
        if [[ ! -f "${MIRROR_OUT_FILE}" ]]; then
            echo >&2 "${MIRROR_OUT_FILE} not found" && return 1
        fi
        sed -n '/To use the new mirrored repository for upgrades, use the following to create an ImageContentSourcePolicy:/,/configmap.*/{//!p;}' "${MIRROR_OUT_FILE}"  | grep -v '^$' > "${ICSP_FILE}"
        run_command "cat ${ICSP_FILE}"
        run_command "oc create -f ${ICSP_FILE}"
    fi
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Get the target upgrades release, by default, OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is the target release
# If it's serial upgrades then override-upgrade file will store the release and overrides OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE
# upgrade-edge file expects a comma separated releases list like target_release1,target_release2,...
export TARGET_RELEASES=("${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}")
if [[ -f "${SHARED_DIR}/upgrade-edge" ]]; then
    release_string="$(< "${SHARED_DIR}/upgrade-edge")"
    # shellcheck disable=SC2207
    TARGET_RELEASES=($(echo "$release_string" | tr ',' ' ')) 
fi
echo "Upgrade targets are ${TARGET_RELEASES[*]}"

# private mirror registry host
# <public_dns>:<port>
if [[ ! -f "${SHARED_DIR}/mirror_registry_url" ]]; then
    echo >&2 "File ${SHARED_DIR}/mirror_registry_url does not exist." && exit 1
fi

MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"
export MIRROR_REGISTRY_HOST

# combine custom registry credential and default pull secret
if [[ ! -f "/var/run/vault/mirror-registry/registry_creds" ]]; then
    echo >&2 "/var/run/vault/mirror-registry/registry_creds does not exist." && exit 1
fi
export PULL_SECRET="${SHARED_DIR}/new_pull_secret"
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${PULL_SECRET}"

trap 'rm -f "${PULL_SECRET}"' ERR EXIT TERM

export MIRROR_OUT_FILE="${SHARED_DIR}/mirror"
export ICSP_FILE="${SHARED_DIR}/icsp.yaml"

for target in "${TARGET_RELEASES[@]}"
do
    export TARGET="${target}"
    if ! check_signed; then
        echo "You're mirroring an unsigned images, don't apply signature"
        APPLY_SIG="false"
        SAVE_SIG_TO_DIR=""
    else
        APPLY_SIG="true"
        SAVE_SIG_TO_DIR=$(mktemp -d)
    fi
    export APPLY_SIG
    export SAVE_SIG_TO_DIR
    mirror_image
    set_proxy_env
    apply_signature
    update_icsp
    rm -f "${MIRROR_OUT_FILE}" "${ICSP_FILE}"
done
