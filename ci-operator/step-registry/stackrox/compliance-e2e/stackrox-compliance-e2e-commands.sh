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
    # REQUIRED for Component Readiness (CR) compliance: Map test suite names in JUnit XML files.
    # CR analyzes test results based on XML content and requires suite names to be changed
    # (e.g., from "validation" to "ACS-lp-interop") for proper association and analysis.
    # Missing or incorrect mapping results in missing CR dashboard data, indicating issues
    # like provisioning failures or post-phase problems that prevent proper XML generation.
    typeset resultsFile="${1:-}"

    if [[ "${MAP_TESTS}" == "true" && -n "${resultsFile}" ]]; then
        if [ -f "${resultsFile}" ]; then
            # Use /tmp/bin/yq since InstallYq was already called
            typeset yqCmd="/tmp/bin/yq"
            : "Mapping test suite name in: ${resultsFile}"
            # Try both XML structures: testsuites wrapper or single testsuite
            # Array notation [] updates ALL test suites in the wrapper, ensuring complete mapping
            "${yqCmd}" eval -ox -iI0 '.testsuites.testsuite[]."+@name" = "ACS-lp-interop"' "${resultsFile}" \
                || "${yqCmd}" eval -ox -iI0 '.testsuite."+@name" = "ACS-lp-interop"' "${resultsFile}" \
                || : "Warning: yq failed to map test suite name for ${resultsFile}" >&2
        fi
    fi

    true
}

function CleanupCollect() {
    # Disable exit on error in cleanup to be resilient to timeouts/interruptions
    # This ensures cleanup completes even if individual operations fail
    set +e
    
    if [[ "${MAP_TESTS}" == "true" ]]; then
        InstallYq

        # Merge XML files into single file for Data Router Reporter step
        #
        # Purpose: Prepare JUnit XML files for Component Readiness (CR) and Data Router
        # - CR needs test suite names mapped (done above with yq) to analyze test results
        # - Data Router sends XML files from SHARED_DIR to Report Portal
        #
        # How it works:
        # 1. Files are modified with yq to set test suite name (required for CR)
        # 2. All XML files are merged into one file using junitparser
        # 3. Merged file is copied to SHARED_DIR for Data Router Reporter step
        #
        # Why merge: Combining multiple XML files into one reduces Kubernetes secret overhead
        # (each file becomes a secret), improving step transition performance and avoiding filename collisions
        typeset resultFile
        typeset fileCount=0
        typeset xmlFiles=()
        
        # Process all files with yq and collect file paths for merging
        while IFS= read -r -d '' resultFile; do
            # Process with yq (modifies file in-place in ARTIFACT_DIR to add test suite name)
            MapTestsForComponentReadiness "${resultFile}" 2>/dev/null || true
            # Basic XML validation: check if file contains testsuite or testsuites element
            if grep -qE '<(testsuite|testsuites)' "${resultFile}" 2>/dev/null; then
                xmlFiles+=("${resultFile}")
                ((fileCount++))
            else
                : "Warning: ${resultFile} does not appear to be a valid JUnit XML file, skipping" >&2
            fi
        done < <(find "${ARTIFACT_DIR}" -type f -iname "*.xml" -print0 2>/dev/null || true)
        
        if [[ ${fileCount} -eq 0 ]]; then
            : "Warning: No XML files found to process for Data Router" >&2
        else
            typeset mergedFile="${SHARED_DIR}/junit-compliance-e2e-merged.xml"
            
            # Try to use junitparser if available, or install it
            if ! command -v junitparser >/dev/null 2>&1; then
                # Try to install junitparser (non-blocking)
                if command -v pip3 >/dev/null 2>&1 || command -v pip >/dev/null 2>&1; then
                    : "Installing junitparser for XML merging..."
                    (pip3 install --user junitparser 2>/dev/null || pip install --user junitparser 2>/dev/null) || true
                    export PATH="${PATH}:${HOME}/.local/bin"
                fi
            fi
            
            # Merge files using junitparser
            if command -v junitparser >/dev/null 2>&1; then
                if junitparser merge "${xmlFiles[@]}" "${mergedFile}" 2>/dev/null; then
                    : "Merged ${fileCount} XML file(s) into ${mergedFile} for Data Router Reporter"
                else
                    : "Warning: junitparser merge failed" >&2
                fi
            else
                : "Warning: junitparser not available, cannot merge XML files" >&2
            fi
        fi
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