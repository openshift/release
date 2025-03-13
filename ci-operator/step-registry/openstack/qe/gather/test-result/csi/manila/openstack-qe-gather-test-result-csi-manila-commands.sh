#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

OCP_TESTING_URL="$(<"${SHARED_DIR}/ocp_testing_url")"

JOB_NUMBER="$(<"${SHARED_DIR}/job_number")"

info "INFO: Get e2e.log from openshift-test CSI Manila test results"

test_url="${OCP_TESTING_URL}/${JOB_NUMBER}/artifact/manilacsi-test-results"
http_code=`curl -k -o /dev/null -s -w "%{http_code}\n" "${test_url}/manilacsi-test.log"`

if [ $http_code -ne 200 ]
then
	info "INFO: Log Not Found with HTTP status code: $http_code in build ${JOB_NUMBER}"
	exit 0
fi

curl -k "${test_url}/manilacsi-test.log" > "${ARTIFACT_DIR}/e2e.log"

info "INFO: Get junit from openshift-test CSI Manila test results"

curl -k -o "${ARTIFACT_DIR}/junit.zip" "${test_url}/*zip*/manilacsi-test-results.zip"

unzip ${ARTIFACT_DIR}/junit.zip -d ${ARTIFACT_DIR} && mv ${ARTIFACT_DIR}/manilacsi-test-results ${ARTIFACT_DIR}/junit

rm -f ${ARTIFACT_DIR}/junit.zip