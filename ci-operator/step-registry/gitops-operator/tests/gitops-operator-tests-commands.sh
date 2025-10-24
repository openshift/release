#!/usr/bin/env bash

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
            echo "Mapping Test Suite Name To: Gitops-lp-interop"
            yq eval -px -ox -iI0 '.testsuite."+@name" = "Gitops-lp-interop"' $results_file
        fi
    fi
}

set -x

unset CI

exit_code=0
scripts/openshift-CI-kuttl-tests.sh
kubectl kuttl test test/openshift/e2e/sequential --config test/openshift/e2e/sequential/kuttl-test.yaml --report xml || exit_code=1


# Move results to Artifacts directory
cp ./kuttl-test.xml ${ARTIFACT_DIR}/junit_gitops-sequential.xml

original_results="${ARTIFACT_DIR}/original_results/"
mkdir "${original_results}"

# Keep a copy of all the original Junit file before modifying it
cp "${ARTIFACT_DIR}/junit_gitops-sequential.xml" "${original_results}/junit_gitops-sequential.xml"

# Map tests if needed for related use cases
mapTestsForComponentReadiness "${ARTIFACT_DIR}/junit_gitops-sequential.xml"

 # Send junit file to shared dir for Data Router Reporter step
cp "${ARTIFACT_DIR}/junit_gitops-sequential.xml" "${SHARED_DIR}"

exit $exit_code