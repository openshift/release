#!/bin/bash

# ==============================================================================
# E2E Limited Preview Interoperability Test Script
#
# This script runs end-to-end interoperability tests for the Sail Operator
# in Limited Preview mode on OpenShift clusters.
#
# It performs the following steps:
# 1. Sets up the Kubernetes environment and switches to the default project.
# 2. Configures the operator namespace from the OPERATOR_NAMESPACE variable
#    (used instead of NAMESPACE to avoid conflicts with global environment).
# 3. Executes the e2e.ocp test suite using the configured test environment.
# 4. Collects test artifacts and saves them as JUnit XML reports.
# 5. Preserves the original exit code from the test execution for proper
#    CI failure reporting, even if artifact collection succeeds.
#
# Required Environment Variables:
#   - SHARED_DIR: Directory containing the kubeconfig file.
#   - OPERATOR_NAMESPACE: The namespace where the operator is installed.
#   - ARTIFACT_DIR: The local directory to store test artifacts.
#
# Notes:
#   - Uses OPERATOR_NAMESPACE instead of NAMESPACE to avoid conflicts with
#     global pipeline variables used during the post phase.
#   - JUnit report files must start with 'junit' prefix for CI recognition.
# ==============================================================================

set -o nounset
set -o errexit
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
    if [[ $MAP_TESTS == "true" ]]; then
        results_file="${1}"
        echo "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            install_yq_if_not_exists
            echo "Mapping Test Suite Name To: ServiceMesh-lp-interop"
            yq eval -px -ox -iI0 '.testsuites.testsuite[]."+@name" = "ServiceMesh-lp-interop"' "${results_file}" || echo "Warning: yq failed for ${results_file}, debug manually" >&2
        fi
    fi
}

export XDG_CACHE_HOME="/tmp/cache"
export KUBECONFIG="$SHARED_DIR/kubeconfig"
# We need to switch to the default project, since the container doesn't have permission to see the project in kubeconfig context
oc project default

# we cannot use NAMESPACE env in servicemesh-sail-operator-e2e-lpinterop-ref.yaml since it overrides some global NAMESPACE env 
# which is used during post phase of step (so the pipeline tried to update secret in openshift operator namespace which resulted in error).
# Due to that, OPERATOR_NAMESPACE env is used in the step ref definition
export NAMESPACE=${OPERATOR_NAMESPACE}

ret_code=0

mkdir ./test_artifacts
ARTIFACTS="$(pwd)/test_artifacts"
export ARTIFACTS
#execute test, do not terminate when there is some failure since we want to archive junit files
make test.e2e.ocp || ret_code=$?

# the junit file name must start with 'junit'
cp ./test_artifacts/report.xml ${ARTIFACT_DIR}/junit-sail-e2e.xml

# Preserve original test result files
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

# report saved status code from make, in case test.e2e.ocp failed with panic in some test case (and junit doesn't contain error)
exit $ret_code
