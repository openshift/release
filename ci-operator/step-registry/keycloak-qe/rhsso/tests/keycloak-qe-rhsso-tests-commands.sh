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
ANSIBLE_EXIT_CODE=$?

if [[ $ANSIBLE_EXIT_CODE -ne 0 ]]; then
  echo " Ansilbe playbook failed with error code $ANSIBLE_EXIT_CODE" 
  exit 1
else
  echo "Execution succesfull"
fi


# if [[ ! -f "/tmp/tests/ansible-tests/junit-results/test-ocp-ci-rhbk-*.xml" ]]; then
#   echo "JUNIT file not found at : /tmp/tests/ansible-tests/junit-results/test-ocp-ci-rhbk-*.xml"
#   exit 1
# else
#   echo "JUNIT file found  "
# fi


#copy junit results to artifacts dir
echo "creating rhsso-tests directory"
mkdir -p $ARTIFACT_DIR/rhsso-tests
echo "copy junit results to artifacts dir"
cp -r  /tmp/tests/ansible-tests/junit-results/test-ocp-ci-rhbk-*.xml $ARTIFACT_DIR/rhsso-tests/junit_rhsso_tests_results.xml

#Parse JUnit sml for failure
JUNIT_FILE="$ARTIFACT_DIR/rhsso-tests/junit_rhsso_tests_results.xml"
if grep -qE "<failure|<error" "$JUNIT_FILE" ; then
  echo " failures or errors found in junit xml "
  exit 1
else
  echo "All tests passed, exiting with success"
  exit 0
fi

