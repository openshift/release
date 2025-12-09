#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function install_yq() {
    # Install yq manually if not found in image
      echo "Installing yq"
      mkdir -p /tmp/bin
      export PATH=$PATH:/tmp/bin/
      curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
       -o /tmp/bin/yq && chmod +x /tmp/bin/yq

      # Verify installation
      cmd_yq="$(/tmp/bin/yq --version 2>/dev/null || true)"
      if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
      else
        # Skip test mapping since yq isn't available
        export MAP_TESTS="false"
      fi
}


function mapTestsForComponentReadiness() {
    if [[ $MAP_TESTS == "true" ]]; then
        results_file="${1}"
        echo "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            echo "Mapping Test Suite Name To: ACSLatest-lp-interop"
            /tmp/bin/yq eval -ox -iI0 '.testsuite."+@name" = "ACSLatest-lp-interop"' "$results_file" || echo "Warning: yq failed for ${results_file}, debug manually" >&2
        fi
    fi
}


# Archive results function
function cleanup-collect() {
    if [[ $MAP_TESTS == "true" ]]; then
      install_yq
      original_results="${ARTIFACT_DIR}/original_results/"
      mkdir "${original_results}" || true
      echo "Collecting original results in ${original_results}"

      # Keep a copy of all the original Junit files before modifying them
      cp -r "${ARTIFACT_DIR}"/junit-* "${original_results}" || echo "Warning: couldn't copy original files" >&2

      # Safely handle filenames with spaces
      find "${ARTIFACT_DIR}" -type f -iname "*.xml" -print0 | while IFS= read -r -d '' result_file; do
        # Map tests if needed for related use cases
        mapTestsForComponentReadiness "${result_file}"
      done

      # Send modified files to shared dir for Data Router Reporter step
      cp -r "${ARTIFACT_DIR}"/junit-* "${SHARED_DIR}" || echo "Warning: couldn't copy files to SHARED_DIR" >&2
    fi
}

# Post test execution
trap 'cleanup-collect' SIGINT SIGTERM ERR EXIT

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

