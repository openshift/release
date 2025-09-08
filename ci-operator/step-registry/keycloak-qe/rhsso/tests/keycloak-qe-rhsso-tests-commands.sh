#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set PATH for OC binary
export PATH=$PATH:/tmp/tests/ansible-tests/

# add user entry in /etc/passwd for current userid
export ANISBLE_REMOTE_USER=default
echo "default:x:$(id -u):0:default user:${HOME}:/sbin/nologin" >> /etc/passwd;

#kubeconfig is mounted from a secret, so its immutable. We have to copy it to some writable location.
cp -L $KUBECONFIG /tmp/kubeconfig

# Run tests
echo "Executing rhsso tests ref"

ansible-playbook -v /tmp/tests/ansible-tests/test-ocp-ci-rhbk.yml --extra-vars "ocp_project_name='${OCP_PROJECT_NAME}'"

#copy junit results to artifacts dir
mkdir -p $ARTIFACT_DIR/rhsso-tests
cp -r /tmp/tests/ansible-tests/junit-results/test-ocp-ci-rhbk-*.xml  $ARTIFACT_DIR/rhsso-tests/junit_rhsso_tests_results.xml

