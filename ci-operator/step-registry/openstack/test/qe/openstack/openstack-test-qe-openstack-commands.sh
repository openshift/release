#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

export OCP_TESTING_URL="$(<"${SHARED_DIR}/ocp_testing_url")"

export JOB_NUMBER="$(<"${SHARED_DIR}/job_number")"

info "INFO: Get openstack-test test results e2e.log"

# Insecure option for testing purpose until https://github.com/openshift/release/pull/61614 is merged and tested
curl --insecure "${OCP_TESTING_URL}/${JOB_NUMBER}/artifact/openstack-test-results/openstack-test.log" > "${ARTIFACT_DIR}/e2e.log"

info "INFO: Get openstack-test test results junit"

# Insecure option for testing purpose until https://github.com/openshift/release/pull/61614 is merged and tested
curl --insecure -o "${ARTIFACT_DIR}/junit.zip" "${OCP_TESTING_URL}/${JOB_NUMBER}/artifact/openstack-test-results/*zip*/openstack-test-results.zip"

unzip ${ARTIFACT_DIR}/junit.zip -d ${ARTIFACT_DIR} && mv ${ARTIFACT_DIR}/openstack-test-results ${ARTIFACT_DIR}/junit

rm -f ${ARTIFACT_DIR}/junit.zip