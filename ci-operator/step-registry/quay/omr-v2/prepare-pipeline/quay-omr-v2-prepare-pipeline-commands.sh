#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

umask 077

pipeline_image_file="${SHARED_DIR}/omr_v2_pipeline_image"
pipeline_image_tmp=""
published=false

cleanup() {
    local status=$?

    trap - EXIT TERM
    set +o errexit
    if [[ -n "${pipeline_image_tmp}" ]]; then
        rm -f -- "${pipeline_image_tmp}"
    fi
    if [[ "${published}" != true ]]; then
        rm -f -- "${pipeline_image_file}"
    fi
    exit "${status}"
}

terminate() {
    exit 143
}

trap cleanup EXIT
trap terminate TERM

: "${OMR_V2_IMAGE:?OMR_V2_IMAGE must identify the PR-built mirror-registry image}"

if [[ ! "${OMR_V2_IMAGE}" =~ ^[A-Za-z0-9._/@:-]+$ ]]; then
    echo "The PR-built OMR v2 image pullspec contains unexpected characters." >&2
    exit 1
fi

rm -f -- "${pipeline_image_file}"
pipeline_image_tmp=$(mktemp "${SHARED_DIR}/.omr_v2_pipeline_image.XXXXXX")
printf '%s\n' "${OMR_V2_IMAGE}" > "${pipeline_image_tmp}"
chmod 0644 "${pipeline_image_tmp}"
mv -f -- "${pipeline_image_tmp}" "${pipeline_image_file}"
pipeline_image_tmp=""
published=true

echo "Prepared the PR-built OMR v2 pipeline image for the install step."
