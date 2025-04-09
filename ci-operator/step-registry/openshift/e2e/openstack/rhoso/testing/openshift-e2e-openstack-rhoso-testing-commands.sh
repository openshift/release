#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

failed=0
mkdir -v $ARTIFACT_DIR/junit
SHARED_DIR=/tmp/secret
export KUBECONFIG=$SHARED_DIR/rhoso_kubeconfig

echo Cleaning the artifacts from the shiftstackclient pod before running tests
oc -n openstack rsh shiftstackclient-shiftstack bash -c 'rm -rf ~/artifacts/ansible_logs/'

echo Ensure SHIFTSTACK_TEST_SUITES_LIST is in json format
echo ${SHIFTSTACK_TEST_SUITES_LIST} | jq .

echo Removing proxy-url from rhoso-kubeconfig - required by observability tests on openstack-test
# It's not possible to access the underlying OCP using the proxy from the shiftstackclient pod:
oc -n openstack rsh shiftstackclient-shiftstack bash -c "grep -v proxy-url /home/cloud-admin/incluster-kubeconfig/kubeconfig > /home/cloud-admin/rhoso-kubeconfig" || failed=$?

TEST_COMMAND="source ~/.bashrc && cd shiftstack-qa/ && \
    ansible-navigator run playbooks/ocp_testing.yaml \
    -e @jobs_definitions/${SHIFTSTACK_PROVISION_JOB_DEFINITION}.yaml \
    -e stages=${SHIFTSTACK_TEST_SUITES_LIST} \
    -e ocp_cluster_name=ostest -e user_cloud=shiftstack \
    -e hypervisor=${LEASED_RESOURCE} -e rhoso_kubeconfig=/home/cloud-admin/rhoso-kubeconfig"

echo Running command "${TEST_COMMAND}"
oc -n openstack rsh shiftstackclient-shiftstack bash -c "${TEST_COMMAND}" || failed=$?

echo Gathering artifacts
oc rsync -n openstack --exclude='installation' \
    shiftstackclient-shiftstack:/home/cloud-admin/artifacts/ ${ARTIFACT_DIR}  || failed=$?
mv -v ${ARTIFACT_DIR}/ansible_logs/*xml ${ARTIFACT_DIR}/junit  || failed=$?
find ${ARTIFACT_DIR} -name 'junit_e2e__*.xml' -exec cp -v {} ${ARTIFACT_DIR}/junit \; || failed=$?

# Fail job if any testcase fail
grep '^<testsuite' ${ARTIFACT_DIR}/junit/junit_e2e__*.xml | grep -vq 'failures="0"' && failed=1 || failed=0

[ -n "$failed" ] && { echo "Return code $failed"; exit $failed; }
