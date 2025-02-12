#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

jq_query=""

info "INFO: Check for the OpenShift release version value that will serve for search the correct job"
if [ -z "${OPENSHIFT_RELEASE}" ]; then
	info "ERROR: None OpenShift release was set"
	exit 1
else
	printf '%s' "${OPENSHIFT_RELEASE}" > "${SHARED_DIR}/ocp_release"
fi

info "INFO: Check for the periodic job config that will serve for search the correct job"
if [ -z "${TEST_CONFIG_FILE}" ]; then
	info "ERROR: None test config file was set"
	exit 1
fi

info "INFO: Choose the correct QE job type, ci for multijob, periodic for periodic multijob"
if [[ "${OCP_TESTING}" == "ci" ]]; then
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/CI_OCP_TESTING" "${SHARED_DIR}/ocp_testing_url"
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/CI_OCP_TESTING_LOGS" "${SHARED_DIR}/ocp_testing_logs_url"
	jq_query=".builds[] | select(.actions[].parameters[]? | select(.name==\"TEST_CONFIG_FILE\" and (.value | startswith(\"${TEST_CONFIG_FILE}\")))) | .number"
else
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/SUBJOB_OCP_TESTING" "${SHARED_DIR}/ocp_testing_url"
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/SUBJOB_OCP_TESTING_LOGS" "${SHARED_DIR}/ocp_testing_logs_url"
	jq_query=".builds[] | select(.actions[].parameters[]? | select(.name==\"OPENSHIFT_RELEASE\" and .value==\"${OPENSHIFT_RELEASE}\")) | select(.actions[].parameters[]? | select(.name==\"TEST_CONFIG_FILE\" and (.value | startswith(\"${TEST_CONFIG_FILE}\")))) | .number"
fi

export OCP_TESTING_URL="$(<"${SHARED_DIR}/ocp_testing_url")"

info "INFO: Get the job number that match the OpenShift release version and the job config type"
# Insecure option for testing purpose until https://github.com/openshift/release/pull/61614 is merged and tested 
job_number=`curl -k "${OCP_TESTING_URL}/api/json?tree=builds\[number,status,timestamp,id,duration,result,url,actions\[parameters\[name,value\]\]\]" | jq "${jq_query}" | head -1`

info "INFO: Check if the job number exists"
if [ -z "${job_number}" ]
then
	info "ERROR: The ${TEST_CONFIG_FILE} job hasn't run yet"
	exit 1
else
	info "INFO: The ${TEST_CONFIG_FILE} job ran on build ${job_number} and it's ready to collect its results"
	printf '%s' "${job_number}" > "${SHARED_DIR}/job_number"
fi