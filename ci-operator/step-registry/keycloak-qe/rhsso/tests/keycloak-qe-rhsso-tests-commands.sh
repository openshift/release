#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set PATH for OC binary
export PATH=$PATH:/tmp/tests/ansible-tests/

# Configure env for test run
cp $KUBECONFIG /tmp/kubeconfig
export KUBECONFIG=/tmp/kubeconfig
export PATH=/tmp/tests/ansible-tests/:$PATH

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
OCP_API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
OCP_CRED_USR="kubeadmin"
OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
oc login ${OCP_API_URL} --username=${OCP_CRED_USR} --password=${OCP_CRED_PSW} --insecure-skip-tls-verify=true



# Run tests
echo "Executing rhsso tests ref"

ansible-playbook -v /tmp/tests/ansible-tests/test-ocp-ci-rhbk.yml --extra-vars "ocp_project_name='${OCP_PROJECT_NAME}'"

sleep 3600

#copy junit results to artifacts dir
mkdir -p $ARTIFACT_DIR/rhsso-tests
cp -r /tmp/tests/ansible-tests/junit-results/test-ocp-ci-rhbk-*.xml  $ARTIFACT_DIR/rhsso-tests/junit_rhsso_tests_results.xml

