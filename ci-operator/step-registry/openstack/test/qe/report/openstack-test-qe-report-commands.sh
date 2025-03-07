#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

export OCP_TESTING_URL="$(<"${SHARED_DIR}/ocp_testing_url")"

export JOB_NUMBER="$(<"${SHARED_DIR}/job_number")"

info "INFO: Get OpenShift on OpenStack QE CI test results"

test_url="${OCP_TESTING_URL}/${JOB_NUMBER}/testReport/api/json"

fail_count=`curl --insecure -s $test_url | jq '.failCount'`

if [ $fail_count -gt 0 ]
then
	info "ERROR: $fail_count tests have not been passed"
	exit 1
fi