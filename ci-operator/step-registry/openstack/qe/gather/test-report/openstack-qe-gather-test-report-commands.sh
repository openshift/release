#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

OCP_TESTING_URL="$(<"${SHARED_DIR}/ocp_testing_url")"

JOB_NUMBER="$(<"${SHARED_DIR}/job_number")"

info "INFO: Get the test report from build ${JOB_NUMBER}"

test_url="${OCP_TESTING_URL}/${JOB_NUMBER}/testReport/api/json"

fail_count=`curl -k -s $test_url | jq '.failCount'`

if [ $fail_count -gt 0 ]
then
	info "ERROR: $fail_count tests have not been passed"
	exit 1
fi