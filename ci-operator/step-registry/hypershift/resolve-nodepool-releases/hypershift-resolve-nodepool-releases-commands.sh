#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

resolve_release_image() {
    local version=$1
    local stream="${2:-ci}"
    if [[ -z "${version}" ]]; then
        return 1
    fi
    local pullspec
    pullspec=$(curl -q -L -s --retry 5 --retry-delay 10 \
        "https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/${version}.0-0.${stream}/latest" \
        | jq -r ".pullSpec // empty")
    if [[ -z "${pullspec}" ]]; then
        echo "WARNING: Failed to resolve release image for version ${version}, stream ${stream}" >&2
        return 1
    fi
    echo "${pullspec}"
}

OUTPUT_FILE="${SHARED_DIR}/nodepool_release_images"
: > "${OUTPUT_FILE}"

for n in 1 2 3 4; do
    version_var="NODEPOOL_N${n}_VERSION"
    version="${!version_var:-}"
    if [[ -n "${version}" ]]; then
        resolved=$(resolve_release_image "${version}") || true
        if [[ -n "${resolved}" ]]; then
            echo "OCP_IMAGE_N${n}=\"${resolved}\"" >> "${OUTPUT_FILE}"
            echo "Resolved N${n} (${version}): ${resolved}"
        else
            echo "WARNING: Could not resolve N${n} version ${version}, skipping"
        fi
    fi
done

echo "Resolved nodepool release images:"
cat "${OUTPUT_FILE}"
