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
  echo "JOB_LINK=${JOB_LINK}"
  echo "SLACK_WEBHOOK_URL=$(cat /usr/local/cs-qe-credentials/slack_webhook_url)"
  echo "CONSOLE_CLIENT_SECRET=$(cat /usr/local/cs-qe-credentials/console_client_secret)"
} > "${podman_env_file}"

if [[ "${OCM_FVT_REPORT_JIRA:-true}" == "true" ]]; then
  echo "ENABLE_JIRA_REPORTING=true" >> "${podman_env_file}"
fi

if [[ -n "${OCM_FVT_OCM_ENV:-}" ]]; then
  echo "OCM_ENV=${OCM_FVT_OCM_ENV}" >> "${podman_env_file}"
fi

if [[ -n "${OCM_FVT_EXTRA_ENVS:-}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    echo "${line}" >> "${podman_env_file}"
  done <<< "${OCM_FVT_EXTRA_ENVS}"
fi

cred_sources='source /usr/local/cs-qe-credentials/ocm-tokens'
if [[ "${OCM_FVT_REPORT_JIRA:-true}" == "true" ]]; then
  cred_sources="${cred_sources}; source /usr/local/cs-qe-credentials/jira-cred"
fi

env -i bash --norc --noprofile -c "
  ${cred_sources}
  env | grep -v '^_='
" >> "${podman_env_file}"

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

ocm_fvt_output="${ARTIFACT_DIR}/ocm-fvt-results"
mkdir -p "${ocm_fvt_output}"
chmod 1777 "${ocm_fvt_output}"
podman_args+=("-v" "${ocm_fvt_output}:/ocm-backend-tests/output:z")
podman_args+=(--rm)

ocmtest_args=(test --service "${OCM_FVT_SERVICE:-cms}" --job "${OCM_FVT_JOB_NAME}")
if [[ "${OCM_FVT_REPORT_JIRA:-true}" == "true" ]]; then
  ocmtest_args+=(--reportJiraTicket)
fi

echo "=== ocmci image digest ==="
podman pull \
  --authfile /usr/local/cs-qe-credentials/.dockerconfigjson \
  quay.io/redhat-services-prod/ocmci/ocmci:latest
podman inspect \
  --format '{{index .RepoDigests 0}}' \
  quay.io/redhat-services-prod/ocmci/ocmci:latest \
  || echo "WARNING: failed to get ocmci image digest"
echo "=========================="

echo "Running ocmtest: ${ocmtest_args[*]}"
exit_code=0
podman run \
  "${podman_args[@]}" \
  quay.io/redhat-services-prod/ocmci/ocmci:latest \
  ocmtest "${ocmtest_args[@]}" || exit_code=$?

# Copy only the merged report.xml to avoid inflated test counts from
# per-phase XMLs that include all Ginkgo specs (including skipped).
find "${ocm_fvt_output}" -type f -name 'report.xml' -print0 | while IFS= read -r -d '' xml_file; do
  cp "${xml_file}" "${ARTIFACT_DIR}/junit-ocm-fvt-report.xml"
done

exit "${exit_code}"