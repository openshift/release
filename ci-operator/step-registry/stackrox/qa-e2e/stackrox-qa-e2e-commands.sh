#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function install_yq_if_not_exists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
            -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    fi
}

function mapTestsForComponentReadiness() {
    # Safely patch a JUnit XML results file to set the testsuite name to "MTA-lp-interop".
    # This function:
    #  - is a no-op unless MAP_TESTS=="true"
    #  - ensures yq is available
    #  - tries the common XML shapes (.testsuite and .testsuites.testsuite[0])
    #  - warns on failure but does not cause the script to exit (keeps CI artifacts archiving)
    results_file="${1:-}"
    if [[ "${MAP_TESTS:-}" != "true" || -z "${results_file}" ]]; then
        return 0
    fi

    echo "Patching Tests Result File: ${results_file}"
    if [ ! -f "${results_file}" ]; then
        echo "Warning: results file not found: ${results_file}" >&2
        return 0
    fi

    install_yq_if_not_exists

    # Try to map common XML root shapes. Each attempt is allowed to fail; the final
    # fallback prints a warning but does not fail the step (prevents errexit from aborting).
    yq eval -px -ox -iI0 '.testsuite."+@name" = "MTA-lp-interop"' "${results_file}" \
      || yq eval -px -ox -iI0 '.testsuites.testsuite[0]."+@name" = "MTA-lp-interop"' "${results_file}" \
      || { echo "Warning: yq failed to map test suite name for ${results_file}; inspect file manually" >&2; }
}

job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"

# this part is used for interop opp testing under stolostron/policy-collection
if [ ! -f ".openshift-ci/dispatch.sh" ];then
  if [ ! -d "stackrox" ];then
    git clone https://github.com/stackrox/stackrox.git
  fi
  cd stackrox || exit
fi

.openshift-ci/dispatch.sh "${job}"

original_results="${ARTIFACT_DIR}/original_results"
mkdir -p "${original_results}"

# Find xml files safely (null-delimited) and process them. This avoids word-splitting
# and is robust to filenames containing spaces/newlines.
while IFS= read -r -d '' result_file; do
    # Compute relative path under ARTIFACT_DIR to preserve structure in original_results
    rel_path="${result_file#$ARTIFACT_DIR/}"
    dest_path="${original_results}/${rel_path}"
    mkdir -p "$(dirname "$dest_path")"
    cp -- "$result_file" "$dest_path"

    # Map tests if needed for related use cases
    mapTestsForComponentReadiness "$result_file"

    # Send junit file to shared dir for Data Router Reporter step (use basename to avoid overwriting files with same name)
    cp -- "$result_file" "${SHARED_DIR}/$(basename "$result_file")"
done < <(find "${ARTIFACT_DIR}" -type f -iname "*.xml" -print0)
