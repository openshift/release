#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

export OCP_TESTING_URL="$(<"${SHARED_DIR}/ocp_testing_url")"
export OCP_TESTING_LOGS_URL="$(<"${SHARED_DIR}/ocp_testing_logs_url")"

export JOB_NUMBER="$(<"${SHARED_DIR}/job_number")"

info "INFO: Get the must-gather artifacts from the cluster in the build ${JOB_NUMBER}"

logs_url="${OCP_TESTING_LOGS_URL}/${JOB_NUMBER}/infrared/.workspaces"

workspace=$(curl -k -s "${logs_url}/" | grep -oP 'workspace_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}' | sort | tail -n 1)

gather_list=$(curl -k -s "$logs_url/$workspace/" | grep -oP 'must-gather-[^"]+.gz' | sort -u)

if [ ! -z "$gather_list" ]
then
	for must_gather in $gather_list; do
		wget --no-check-certificate -r -np -nH --cut-dirs=8 -R "index.html*" -P "${ARTIFACT_DIR}/" "$logs_url/$workspace/$must_gather/" >/dev/null 2>&1
	done
fi

info "INFO: Get the test report of the build ${JOB_NUMBER}"

test_url="${OCP_TESTING_URL}/${JOB_NUMBER}/testReport/api/json"

fail_count=`curl -k -s $test_url | jq '.failCount'`

if [ $fail_count -gt 0 ]
then
	info "ERROR: $fail_count tests have not been passed"
	exit 1
fi