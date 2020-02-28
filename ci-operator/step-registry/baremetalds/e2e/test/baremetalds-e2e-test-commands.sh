#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds test command ************"
env | sort

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

echo "Executing baremetal ds conformance tests"

ls -ll ${SHARED_DIR}

#test_suite=openshift/conformance/parallel
#if [[ -e "${SHARED_DIR}/test-suite.txt" ]]; then
#    test_suite=$(<"${SHARED_DIR}/test-suite.txt")
#fi
#
#openshift-tests run "${test_suite}" \
#    --provider "${TEST_PROVIDER}" \
#    -o /tmp/artifacts/e2e.log \
#    --junit-dir /tmp/artifacts/junit
