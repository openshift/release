#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

RELEASE_CONTROLLER_URL="https://amd64.ocp.releases.ci.openshift.org"
REGISTRY_AUTH="/etc/ci-pull-credentials/.dockerconfigjson"
STREAMS=(ci nightly)

resolve_from_stream() {
    local version=$1
    local stream=$2
    local url="${RELEASE_CONTROLLER_URL}/api/v1/releasestream/${version}.0-0.${stream}/latest"
    local response http_code body pullspec

    for attempt in 1 2 3; do
        response=$(curl -q -L -s -w "\n%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 10 --max-time 30 "${url}")
        http_code=$(echo "${response}" | tail -1)
        body=$(echo "${response}" | sed '$d')

        if [[ "${http_code}" == "200" ]]; then
            pullspec=$(echo "${body}" | jq -r ".pullSpec // empty")
            if [[ -n "${pullspec}" ]]; then
                echo "${pullspec}"
                return 0
            fi
        fi
        echo "Attempt ${attempt}/3 failed for ${version} stream=${stream} (HTTP ${http_code}), retrying..." >&2
        sleep $((attempt * 5))
    done
    return 1
}

verify_image_pullable() {
    local pullspec=$1
    local auth_args=""
    if [[ -f "${REGISTRY_AUTH}" ]]; then
        auth_args="-a ${REGISTRY_AUTH}"
    fi

    # Check 1: release tag manifest exists and is the right architecture
    # shellcheck disable=SC2086
    oc image info --filter-by-os linux/amd64 ${auth_args} "${pullspec}" &>/dev/null || return 1

    # Check 2: internal component digests are still alive in the registry.
    # The release tag can outlive its component digests when the CI registry
    # garbage-collects old images. Extract the MCO digest from the release
    # metadata and verify it is actually pullable.
    local mco_digest
    # shellcheck disable=SC2086
    mco_digest=$(oc adm release info ${auth_args} "${pullspec}" --image-for=machine-config-operator 2>/dev/null) || return 1
    # shellcheck disable=SC2086
    oc image info --filter-by-os linux/amd64 ${auth_args} "${mco_digest}" &>/dev/null || return 1
}

resolve_release_image() {
    local version=$1
    if [[ -z "${version}" ]]; then
        return 1
    fi

    for stream in "${STREAMS[@]}"; do
        local pullspec
        if pullspec=$(resolve_from_stream "${version}" "${stream}"); then
            if verify_image_pullable "${pullspec}"; then
                echo "${pullspec}"
                return 0
            fi
            echo "WARNING: ${version} stream=${stream} resolved to ${pullspec} but image is not available in registry" >&2
        else
            echo "WARNING: ${version} stream=${stream} has no Accepted release" >&2
        fi
    done

    echo "ERROR: Failed to resolve a pullable release image for version ${version} across streams: ${STREAMS[*]}" >&2
    return 1
}

OUTPUT_FILE="${SHARED_DIR}/nodepool_release_images"
: > "${OUTPUT_FILE}"

failures=0
for n in 1 2 3 4; do
    version_var="NODEPOOL_N${n}_VERSION"
    version="${!version_var:-}"
    if [[ -n "${version}" ]]; then
        if resolved=$(resolve_release_image "${version}"); then
            echo "export OCP_IMAGE_N${n}=\"${resolved}\"" >> "${OUTPUT_FILE}"
            echo "Resolved N${n} (${version}): ${resolved}"
        else
            echo "ERROR: Could not resolve N${n} version ${version}"
            failures=$((failures + 1))
        fi
    fi
done

echo "--- Resolved nodepool release images ---"
cat "${OUTPUT_FILE}"

if [[ ${failures} -gt 0 ]]; then
    echo "ERROR: Failed to resolve ${failures} release image(s)."
    exit 1
fi
