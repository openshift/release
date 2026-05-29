#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${OCM_FVT_JOB_NAME:-}" ]]; then
  echo "ERROR: OCM_FVT_JOB_NAME is required but not set" >&2
  exit 1
fi

JOB_LINK="https://prow.ci.openshift.org/view/gs/test-platform-results/"
if [[ -n "${PULL_NUMBER:-}" ]]; then
  JOB_LINK="${JOB_LINK}pr-logs/pull/openshift_release/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
  JOB_LINK="${JOB_LINK}logs/${JOB_NAME}/${BUILD_ID}"
fi

old_umask=$(umask)
umask 077
podman_env_file="$(mktemp /tmp/podman.env.XXXXXX)"
trap 'rm -f "${podman_env_file}"' EXIT
umask "${old_umask}"

{
  echo "AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-cred"
  echo "SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-shared-vpc-credentials"
  echo "ENABLE_JIRA_REPORTING=true"
  echo "JOB_LINK=${JOB_LINK}"
} > "${podman_env_file}"

if [[ -n "${OCM_FVT_OCM_ENV:-}" ]]; then
  echo "OCM_ENV=${OCM_FVT_OCM_ENV}" >> "${podman_env_file}"
fi

if [[ -n "${OCM_FVT_EXTRA_ENVS:-}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    echo "${line}" >> "${podman_env_file}"
  done <<< "${OCM_FVT_EXTRA_ENVS}"
fi

env -i bash --norc --noprofile -c '
  source /usr/local/cs-qe-credentials/ocm-tokens
  source /usr/local/cs-qe-credentials/jira-cred
  env | grep -v "^_="
' >> "${podman_env_file}"

podman_args=(
  --authfile /usr/local/cs-qe-credentials/.dockerconfigjson
  --env-file "${podman_env_file}"
  "-v" "/usr/local/cs-qe-credentials:/credentials:ro,z"
)

if [[ "${OCM_FVT_GCP_CREDS:-false}" == "true" ]]; then
  podman_args+=(
    "-v" "/usr/local/cs-qe-credentials/osd-ccs-admin.json:/home/ci-user/.gcp/osd-ccs-admin.json:ro,z"
  )
fi

podman_args+=(--rm)

echo "Running ocmtest job: ${OCM_FVT_JOB_NAME}"
podman run \
  "${podman_args[@]}" \
  quay.io/redhat-services-prod/ocmci/ocmci:latest \
  ocmtest test --service cms --job "${OCM_FVT_JOB_NAME}" --reportJiraTicket
