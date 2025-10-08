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

export XDG_CACHE_HOME="/tmp/cache"
export KUBECONFIG="$SHARED_DIR/kubeconfig"
# We need to switch to the default project, since the container doesn't have permission to see the project in kubeconfig context
oc project default

# we cannot use NAMESPACE env in servicemesh-sail-operator-e2e-lpinterop-ref.yaml since it overrides some global NAMESPACE env 
# which is used during post phase of step (so the pipeline tried to update secret in openshift operator namespace which resulted in error).
# Due to that, OPERATOR_NAMESPACE env is used in the step ref definition
export NAMESPACE=${OPERATOR_NAMESPACE}

ret_code=0
#execute test, do not terminate when there is some failure since we want to archive junit files
make test.e2e.ocp || ret_code=$?

# the junit file name must start with 'junit'
cp ./report.xml ${ARTIFACT_DIR}/junit-sail-e2e.xml

# report saved status code from make, in case test.e2e.ocp failed with panic in some test case (and junit doesn't contain error)
exit $ret_code
