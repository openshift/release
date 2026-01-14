#!/bin/bash

# Enable strict mode options including xtrace (-x) and inherit_errexit
# This ensures the script exits immediately if any command fails, including
# commands in pipelines and sub-shells. xtrace helps with post-mortem analysis.
set -euxo pipefail; shopt -s inherit_errexit

function InstallYq() {
    : "Installing yq if not available..."

    # Install yq manually if not found in image
    mkdir -p /tmp/bin
    export PATH="${PATH}:/tmp/bin"

    # Get architecture and download yq
    # Command substitution in variable assignment won't cause script exit on failure
    typeset arch=""
    arch="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"

    curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
        -o /tmp/bin/yq && chmod +x /tmp/bin/yq

    # Verify installation
    # Using || true to prevent script exit if yq is not available
    typeset cmdYq=""
    cmdYq="$(/tmp/bin/yq --version || true)"

    if [ -n "${cmdYq}" ]; then
        : "yq installed: ${cmdYq}"
    else
        : "Warning: yq installation failed, test mapping will be skipped"
    fi

    true
}

function MapTestsForComponentReadiness() {
    typeset resultsFile="${1:-}"

    if [[ "${MAP_TESTS}" == "true" && -n "${resultsFile}" ]]; then
        if [ -f "${resultsFile}" ]; then
            # Check if yq is available before attempting to use it
            typeset yqCmd=""
            if command -v yq >/dev/null 2>&1; then
                yqCmd="yq"
            elif [ -f /tmp/bin/yq ]; then
                yqCmd="/tmp/bin/yq"
            fi

            if [ -n "${yqCmd}" ]; then
                : "Mapping test suite name in: ${resultsFile}"
                "${yqCmd}" eval -ox -iI0 '.testsuite."+@name" = "ACS-lp-interop"' "${resultsFile}" || : "Warning: yq failed for ${resultsFile}"
            else
                : "Warning: yq not available, skipping test mapping for ${resultsFile}"
            fi
        fi
    fi

    true
}

function CleanupCollect() {
    if [[ "${MAP_TESTS}" == "true" ]]; then
        InstallYq

        typeset originalResults="${ARTIFACT_DIR}/original_results"
        mkdir -p "${originalResults}"

        # Keep a copy of all the original JUnit files
        cp -r "${ARTIFACT_DIR}"/junit-* "${originalResults}" || : "Warning: couldn't copy original files"

        # Safely handle filenames with spaces using null-delimited find
        typeset resultFile
        while IFS= read -r -d '' resultFile; do
            MapTestsForComponentReadiness "${resultFile}"
        done < <(find "${ARTIFACT_DIR}" -type f -iname "*.xml" -print0 || true)

        # Send modified files to shared dir
        cp -r "${ARTIFACT_DIR}"/junit-* "${SHARED_DIR}" || : "Warning: couldn't copy files to SHARED_DIR"
    fi

    true
}

# Set trap for cleanup on exit
trap 'CleanupCollect' EXIT

# Determine job name from test suite or job name safe
typeset job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"

# Logic for interop testing
# Clone stackrox repo if dispatch script doesn't exist in current directory
if [ ! -f ".openshift-ci/dispatch.sh" ]; then
    if [ ! -d "stackrox" ]; then
        git clone https://github.com/stackrox/stackrox.git
    fi
    cd stackrox
fi

# Execute dispatch script
.openshift-ci/dispatch.sh "${job}"

# Explicitly return success to ensure script exits with code 0
true