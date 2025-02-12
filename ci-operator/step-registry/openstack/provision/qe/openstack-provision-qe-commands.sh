#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if [ -z "${OCP_RELEASE}" ]; then
	info "No OCP release was set"
	exit 1
else
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/OCP_RELEASE" "${SHARED_DIR}/ocp_release"
fi

if [[ "${OCP_TESTING}" == "ci" ]]; then
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/CI_OCP_TESTING" "${SHARED_DIR}/ocp_testing_url"
else
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/SUBJOB_OCP_TESTING" "${SHARED_DIR}/ocp_testing_url"
fi

export OCP_TESTING_URL="$(<"${SHARED_DIR}/ocp_testing_url")"

export JQ_QUERY=".builds[] | {number, OPENSHIFT_RELEASE: (.actions[].parameters[]?| select(.name==\"OCP_RELEASE\" and .value==\"${OCP_RELEASE}\") | .value)}"

curl "${OCP_TESTING_URL}/api/json?tree=builds\[number,status,timestamp,id,duration,result,url,actions\[parameters\[name,value\]\]\]" | jq "${JQ_QUERY}" | jq -s '.[0].number' > "${SHARED_DIR}/job_number"