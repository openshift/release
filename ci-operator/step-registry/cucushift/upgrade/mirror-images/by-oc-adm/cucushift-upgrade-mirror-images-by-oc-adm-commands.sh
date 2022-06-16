#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Check if a build is signed
function check_signed() {
    local digest algorithm hash_value response
    digest="$(echo "${target}" | cut -f2 -d@)"
    algorithm="$(echo "${digest}" | cut -f1 -d:)"
    hash_value="$(echo "${digest}" | cut -f2 -d:)"
    response=$(curl --silent --output /dev/null --write-out %"{http_code}" "https://mirror2.openshift.com/pub/openshift-v4/signatures/openshift/release/${algorithm}=${hash_value}/signature-1")
    if (( response == 200 )); then
        echo "${target} is signed" && return 0
    else
        echo "Seem like ${target} is not signed" && return 1
    fi
}

function mirror_image(){
    mirror_release_image="${MIRROR_REGISTRY_HOST}/${target#*/}"
    mirror_release_image_repo="${mirror_release_image%:*}"
    mirror_release_image_repo="${mirror_release_image_repo%@sha256*}"

    target_version=$(oc adm release info "${target}" --output=json | jq .metadata.version)
   
    echo "Mirroring ${target_version} (${target}) to ${mirror_release_image_repo}"

    oc adm release mirror -a "${new_pull_secret}" --insecure=true \
        --from="${target}" \
        --to="${mirror_release_image_repo}" \
        --apply-release-image-signature="${apply_sig}" | tee "${mirror_out_file}"
}

function update_icsp(){
    source_release_image_repo="${RELEASE_IMAGE_LATEST%:*}"
    source_release_image_repo="${source_release_image_repo%@sha256*}"
    if [[ "${source_release_image_repo}" != "${mirror_release_image_repo}" ]] && ! oc get ImageContentSourcePolicy example -oyaml; then
        echo "Target image has different repo with source image and icsp example is not present, creating icsp"
        if [[ ! -f "${mirror_out_file}" ]]; then
            echo >&2 "${mirror_out_file} not found" && return 1
        fi
        sed -n '/To use the new mirrored repository for upgrades, use the following to create an ImageContentSourcePolicy:/,/configmap\/sha256.*/{//!p;}' "${mirror_out_file}"  | grep -v '^$' > "${icsp_file}"
        echo "cat ${icsp_file}:"
        cat ${icsp_file}
        oc create -f "${icsp_file}"
    fi
}

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]] 
then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# private mirror registry host
# <public_dns>:<port>
if [[ ! -f "${SHARED_DIR}/mirror_registry_url" ]]; then
    echo >&2 "File ${SHARED_DIR}/mirror_registry_url does not exist." && exit 1
fi

MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"

# combine custom registry credential and default pull secret
if [[ ! -f "/var/run/vault/mirror-registry/registry_creds" ]]; then
    echo >&2 "/var/run/vault/mirror-registry/registry_creds does not exist." && exit 1
fi
new_pull_secret="${SHARED_DIR}/new_pull_secret"
registry_cred=$(head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0)
jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"

trap 'rm -f "${new_pull_secret}"' ERR EXIT TERM

mirror_out_file="${SHARED_DIR}/mirror"
icsp_file="${SHARED_DIR}/icsp.yaml"
target="${RELEASE_IMAGE_TARGET}"
apply_sig="true"
if ! check_signed; then
    echo "You're mirroring an unsigned images, don't apply signature"
    apply_sig="false"
fi
mirror_image 
update_icsp