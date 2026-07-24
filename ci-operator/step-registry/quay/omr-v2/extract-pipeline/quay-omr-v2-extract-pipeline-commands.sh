#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
umask 077

archive_file="${SHARED_DIR}/omr_v2_pipeline_archive.tar.gz"
work_dir=""

cleanup() {
    local status=$?

    trap - EXIT TERM
    set +o errexit
    if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
        rm -rf -- "${work_dir}"
    fi
    if [[ "${status}" -ne 0 ]]; then
        rm -f -- "${archive_file}"
    fi
    exit "${status}"
}

terminate() {
    exit 143
}

trap cleanup EXIT
trap terminate TERM

: "${OMR_V2_IMAGE:?OMR_V2_IMAGE must identify the PR-built mirror-registry image}"

for command in awk grep oc sha256sum tar; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the OMR v2 extraction step image." >&2
        exit 1
    fi
done

mkdir -p "${ARTIFACT_DIR}"
rm -f -- "${archive_file}"
work_dir=$(mktemp -d /tmp/quay-omr-v2-extract.XXXXXX)
chmod 0700 "${work_dir}"
auth_file="${work_dir}/registry-auth.json"
extract_dir="${work_dir}/extract"
archive_tmp="${work_dir}/mirror-registry.tar.gz"
archive_listing="${work_dir}/archive-listing.txt"
mkdir -p "${extract_dir}"

# Log in to the CI build registry without using an in-cluster kubeconfig.
unset KUBECONFIG
oc registry login --to="${auth_file}"
chmod 0600 "${auth_file}"

oc image extract "${OMR_V2_IMAGE}" \
    --registry-config="${auth_file}" \
    --path="/mirror-registry.tar.gz:${extract_dir}"
if [[ ! -s "${extract_dir}/mirror-registry.tar.gz" ]]; then
    echo "The PR-built OMR v2 image does not contain /mirror-registry.tar.gz." >&2
    exit 1
fi
mv -- "${extract_dir}/mirror-registry.tar.gz" "${archive_tmp}"

tar -tzf "${archive_tmp}" > "${archive_listing}"
for required_entry in \
    mirror-registry \
    image-archive.tar \
    execution-environment.tar; do
    if ! grep -Fxq "${required_entry}" "${archive_listing}"; then
        echo "The PR-built OMR v2 archive is missing ${required_entry}." >&2
        exit 1
    fi
done

chmod 0644 "${archive_tmp}"
mv -- "${archive_tmp}" "${archive_file}"
sha256sum "${archive_file}" | awk '{print $1}' > "${ARTIFACT_DIR}/mirror-registry-pipeline-sha256.txt"
printf '%s\n' "${OMR_V2_IMAGE}" > "${ARTIFACT_DIR}/mirror-registry-pipeline-image.txt"

echo "Extracted the OMR v2 offline installer from the PR-built pipeline image."
