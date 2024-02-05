#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set PATH for OC binary
export PATH=$PATH:/tmp/tests/ansible-tests/

# Configure env for test run
cp $KUBECONFIG /tmp/kubeconfig
export KUBECONFIG=/tmp/kubeconfig

# Run tests
echo "Executing rhsso tests ref"

ansible-playbook -v /tmp/tests/ansible-tests/test-ocp-ci-rhbk.yml --extra-vars "ocp_project_name='${OCP_PROJECT_NAME}'"

#copy junit results to artifacts dir
mkdir -p $ARTIFACT_DIR/rhsso-tests
cp -r /tmp/tests/ansible-tests/junit-results/test-ocp-ci-rhbk-*.xml  $ARTIFACT_DIR/rhsso-tests/junit_rhsso_tests_results.xml

