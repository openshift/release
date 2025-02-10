#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

failed=0
mkdir $ARTIFACT_DIR/junit
SHARED_DIR=/tmp/secret
KUBECONFIG=$SHARED_DIR/rhoso_kubeconfig

echo Cleaning the artifacts from the shiftstackclient pod before running tests
oc -n openstack rsh shiftstackclient-shiftstack bash -c 'rm -rf ~/artifacts/ansible_logs/'

echo Ensure SHIFTSTACK_TEST_SUITES_LIST is in json format
echo ${SHIFTSTACK_TEST_SUITES_LIST} | jq .

COMMAND="source ~/.bashrc && cd shiftstack-qa/ && \
    ansible-navigator run playbooks/ocp_testing.yaml \
    -e @jobs_definitions/${SHIFTSTACK_PROVISION_JOB_DEFINITION}.yaml \
    -e stages=${SHIFTSTACK_TEST_SUITES_LIST}
    -e ocp_cluster_name=ostest -e user_cloud=shiftstack \
    -e hypervisor=${LEASED_RESOURCE} -e rhoso_kubeconfig=/home/cloud-admin/incluster-kubeconfig"

echo Running testsuites
oc -n openstack rsh shiftstackclient-shiftstack bash -c "${COMMAND}" || failed=$?

echo Gathering artifacts
oc rsync -n openstack shiftstackclient-shiftstack:/home/cloud-admin/artifacts/ ${ARTIFACT_DIR}  || failed=$?
mv ${ARTIFACT_DIR}/ansible_logs/*xml ${ARTIFACT_DIR}/junit  || failed=$?
[ -n "$failed" ] && { echo "Return code $failed"; exit $failed; }
