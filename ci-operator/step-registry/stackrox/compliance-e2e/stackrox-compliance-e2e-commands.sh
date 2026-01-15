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

    # Skip test mapping if yq installation failed
    /tmp/bin/yq --version || MAP_TESTS=false

    true
}

function MapTestsForComponentReadiness() {
    typeset resultsFile="${1:-}"

    if [[ "${MAP_TESTS}" == "true" && -n "${resultsFile}" ]]; then
        if [ -f "${resultsFile}" ]; then
            # Use /tmp/bin/yq since InstallYq was already called
            typeset yqCmd="/tmp/bin/yq"
            : "Mapping test suite name in: ${resultsFile}"
            "${yqCmd}" eval -ox -iI0 '.testsuite."+@name" = "ACS-lp-interop"' "${resultsFile}" || : "Warning: yq failed for ${resultsFile}"
        fi
    fi

    true
}

function CleanupCollect() {
    # Disable exit on error in cleanup to be resilient to timeouts/interruptions
    # This ensures cleanup completes even if individual operations fail
    set +e
    
    if [[ "${MAP_TESTS}" == "true" ]]; then
        InstallYq || : "Warning: yq installation failed, skipping test mapping"

        typeset originalResults="${ARTIFACT_DIR}/original_results"
        mkdir -p "${originalResults}" 2>/dev/null || true

        # Keep a copy of all the original JUnit files
        cp -r "${ARTIFACT_DIR}"/junit-* "${originalResults}" 2>/dev/null || : "Warning: couldn't copy original files"

        # First, copy all XML files to SHARED_DIR (do this before yq processing)
        # Process files in a single pass: copy first, then modify with yq
        typeset resultFile
        while IFS= read -r -d '' resultFile; do
            # Copy file to SHARED_DIR
            cp -- "${resultFile}" "${SHARED_DIR}/$(basename "${resultFile}")" 2>/dev/null || : "Warning: couldn't copy ${resultFile} to SHARED_DIR"
            
            # Process with yq (can be interrupted without losing files)
            MapTestsForComponentReadiness "${resultFile}" 2>/dev/null || true
        done < <(find "${ARTIFACT_DIR}" -type f -iname "*.xml" -print0 2>/dev/null || true)
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