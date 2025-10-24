#!/bin/bash

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
    if [[ $MAP_TESTS == "true" ]]; then
        results_file="${1}"
        echo "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            install_yq_if_not_exists
            echo "Mapping Test Suite Name To: ACS-lp-interop"
            yq eval -px -ox -iI0 '.testsuite."+@name" = "ACS-lp-interop"' $results_file
        fi
    fi
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

original_results="${ARTIFACT_DIR}/original_results/"
mkdir "${original_results}"

find "${ARTIFACT_DIR}" -type f -iname "*.xml" | while IFS= read -r result_file; do
  # Keep a copy of all the original Junit files before modifying them
  cp "${result_file}" "${original_results}/$(basename "$result_file")"

  # Map tests if needed for related use cases
  mapTestsForComponentReadiness "${result_file}"

  # Send junit file to shared dir for Data Router Reporter step
  cp "$result_file" "${SHARED_DIR}/$(basename "$result_file")"
done
