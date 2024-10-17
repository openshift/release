#!/bin/bash

#set -o nounset
#set -o errexit
#set -o pipefail

set +e

CONFIG="${SHARED_DIR}/install-config.yaml"

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret

job_type="${JOB_TYPE:-}"
user=""
pull_number=""
if [[ "${job_type}" == "presubmit" ]]; then
    user=$(echo "${JOB_SPEC:-}" | jq -r '.refs.pulls[].author')
    pull_number=${PULL_NUMBER:-unknow}
fi
if [[ "${job_type}" == "periodic" ]]; then
    user="cron"
fi
ci_type="prow"
if [[ "${JOB_NAME_SAFE:-}" == "launch" ]]; then
    ci_type="cluster-bot"
fi

cluster_info_file="${ARTIFACT_DIR}/aws-cluster-info-user-tag"
cat <<EOF >>"${cluster_info_file}"
cluster-type ${CI_CLUSTER_TYPE}
job-type ${job_type}
user ${user}
pull-request ${pull_number}
ci ${ci_type}
EOF

if (( ocp_minor_version > 12 || ocp_major_version > 4 )); then
    while read -r TAG VALUE
    do
      printf 'Setting user tag to help cost usage analysis - %s: %s\n' "${TAG}" "${VALUE}"
      yq-go write -i "${CONFIG}" "platform.aws.userTags.${TAG}" "${VALUE}"
    done < "${cluster_info_file}"
else
    echo "userTags on aws get supported from 4.12, skip..."
fi
