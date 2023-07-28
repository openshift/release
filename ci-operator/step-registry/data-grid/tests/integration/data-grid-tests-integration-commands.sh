#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

sleep 7200

# Move the oc client to /usr/bin
mv oc /usr/bin

# Set variables required for execution
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
RESULTS_DIR="/infinispan-operator/test-integration/operator-tests/target/failsafe-reports"
TEST_DIR="/infinispan-operator/test-integration"

# Get the Kubeadmin token
KUBEADMIN_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
oc login -u kubeadmin -p ${KUBEADMIN_PASSWORD} ${API_URL}
KUBEADMIN_TOKEN=$(oc whoami -t)

# Archive results function
function archive-results() {
    # Rename files to add the "junit_" prefix
    cd ${RESULTS_DIR}
    for file in *.xml; do mv $file junit_${file}; done;

    # Copy any .xml from the $RESULTS_DIR into $ARTIFACT_DIR
    cp ./*.xml ${ARTIFACT_DIR}
}

# Execute tests
echo "Executing tests..."
trap archive-results SIGINT SIGTERM ERR EXIT
cd $TEST_DIR
mvn clean verify -B -Dxtf.openshift.namespace=$DG_TEST_NAMESPACE -Dxtf.openshift.url=$API_URL -Dxtf.openshift.master.token=$KUBEADMIN_TOKEN
