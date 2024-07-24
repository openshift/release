#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Config tempuser so Ansible runs smoothly
echo "tempuser:x:$(id -u):$(id -g):tempuser:${HOME}:/bin/bash" >> /etc/passwd
echo "tempuser:x:$(id -G | cut -d' ' -f 2):" >> /etc/group

# Configure env for test run
cp $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig
export PATH=/cli:$PATH

# Run tests
echo "Executing rhscl tests..."
ansible-runner run /tmp/tests/ansible-tests -p deploy-and-test.yml

# Copy results and artifacts to $ARTIFACT_DIR
echo "Archiving /tmp/rhscl_openshift_dir/rhscl-testing-results.xml to ARTIFACT_DIR/junit_rhscl-testing-results.xml..."
cp /tmp/rhscl_openshift_dir/rhscl-testing-results.xml $ARTIFACT_DIR/junit_rhscl-testing-results.xml

echo "Archiving  /tmp/tests/ansible-tests/artifacts/ to ARTIFACT_DIR/rhscl-deploy-and-test"
mkdir -p $ARTIFACT_DIR/rhscl-deploy-and-test
cp -r /tmp/tests/ansible-tests/artifacts/  $ARTIFACT_DIR/rhscl-deploy-and-test/
 
