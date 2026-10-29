#!/bin/bash

#set -o nounset
#set -o errexit
#set -o pipefail

# Version comparison functions using sort -V
function version_ge() {
  # Returns 0 (true) if $1 >= $2
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

set +e

env > "${ARTIFACT_DIR}/prow-ci-env.log"

job_type="${JOB_TYPE:-}"

user=""
pull_number=""
if [[ "${job_type}" == "presubmit" ]]; then
    user=$(echo "${JOB_SPEC:-}" | jq -r '.refs.pulls[].author' | tr -d "[]")
    pull_number=${PULL_NUMBER:-unknown}
elif [[ "${job_type}" == "periodic" ]]; then
    user=$(echo "${JOB_SPEC:-}" | jq -r '.extra_refs[]' |  jq -r '.repo + "-" + .base_ref')
elif [[ "${job_type}" == "postsubmit" ]]; then
    user=$(echo "${JOB_SPEC:-}" | jq -r '.refs' | jq -r '.repo + "-" + .base_ref' | tr -d "[]")
else
    echo "The job type - ${job_type} is not supported yet!"
fi
user=${user:-"empty"}
pull_number=${pull_number:-"empty"}

ci_type="prow"
if [[ "${JOB_NAME_SAFE:-}" == "launch" ]]; then
    ci_type="cluster-bot"
fi

cluster_info_file="${ARTIFACT_DIR}/aws-cluster-info-user-tag"
cat <<EOF >>"${cluster_info_file}"
usage-cluster-type ${USAGE_CLUSTER_TYPE}
usage-job-type ${job_type}
usage-user ${user}
usage-pull-request ${pull_number}
usage-ci-type ${ci_type}
EOF

# for hypershift mgmt cluster, store one more cluster info file for the hosted cluster
if [[ "${USAGE_CLUSTER_TYPE}" == "hypershift-mgmt" ]]; then
  hosted_cluster_file="${SHARED_DIR}/hosted_cluster_info_file"
  cp "${cluster_info_file}" "${hosted_cluster_file}"
  sed -ie 's|usage-cluster-type.*|usage-cluster-type hypershift-hosted|' "${hosted_cluster_file}"
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} -ojsonpath='{.metadata.version}' | cut -d. -f 1,2)
rm /tmp/pull-secret

if version_ge "${ocp_version}" "4.11"; then
    while read -r TAG VALUE
    do
      printf 'Setting user tag to help cost usage analysis - %s: %s\n' "${TAG}" "${VALUE}"
      yq-go write -i "${CONFIG}" "platform.aws.userTags.${TAG}" "${VALUE}"
    done < "${cluster_info_file}"
else
    echo "userTags is only supported for OCP version >= 4.11, skip..."
fi
