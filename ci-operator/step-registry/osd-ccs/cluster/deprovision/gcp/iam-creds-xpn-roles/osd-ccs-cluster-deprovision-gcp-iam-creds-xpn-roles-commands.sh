#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

# login to the service project
GCP_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/osd-ccs-gcp.json"
service_project_id="$(jq -r -c .project_id "${GCP_CREDENTIALS_FILE}")"
gcloud auth activate-service-account --key-file="${GCP_CREDENTIALS_FILE}"
gcloud config set project "${service_project_id}"

function logger() {
  local -r log_level=$1; shift
  local -r log_msg=$1; shift
  echo "$(date -u --rfc-3339=seconds) - ${log_level}: ${log_msg}"
}

function backoff() {
  local attempt=0
  local failed=0
  logger "INFO" "Running Command '$*'"
  while true; do
    eval "$@" && failed=0 || failed=1
    if [[ $failed -eq 0 ]]; then
      break
    fi
    attempt=$(( attempt + 1 ))
    if [[ $attempt -gt 5 ]]; then
      break
    fi
    echo "command failed, retrying in $(( 2 ** attempt )) seconds"
    sleep $(( 2 ** attempt ))
  done
  return $failed
}

working_dir=$(mktemp -d)
pushd "${working_dir}"

logger "INFO" "Removing deleted OSD managed admin IAM policy bindings from GCP host project..."

VPC_PROJECT_ID=$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")
BINDINGS_JSON="bindings.json"
gcloud projects get-iam-policy "${VPC_PROJECT_ID}" --format json > "${BINDINGS_JSON}"

num_roles=$(jq -r .bindings[].role "${BINDINGS_JSON}" | wc -l)
i=0
while [[ $i -lt $num_roles ]]; do
	role=$(jq -r .bindings[$i].role "${BINDINGS_JSON}")
	num_members=$(jq -r .bindings[$i].members[] "${BINDINGS_JSON}" | wc -l)
	j=0
	while [[ $j -lt $num_members ]]; do
		member=$(jq -r .bindings[$i].members[$j] "${BINDINGS_JSON}")
		if [[ "${member}" =~ deleted:serviceAccount: ]]; then
 			CMD="gcloud projects remove-iam-policy-binding ${VPC_PROJECT_ID} --role=\"${role}\" --member=\"${member}\" 1>/dev/null"
			backoff "${CMD}"
		fi
		j=$(($j + 1))
	done

	i=$(($i + 1))
done

rm -fr "${working_dir}"
popd