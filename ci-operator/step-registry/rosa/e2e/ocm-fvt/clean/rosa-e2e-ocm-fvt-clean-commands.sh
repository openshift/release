#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Runs ocmtest --justClean using cluster.ini / .datainfo persisted by rosa-e2e-ocm-fvt
# when OCM_FVT_DEFER_CLEAN=true (so gather posts can run against a live guest first).
# See ROSAENG-67965.

JOB_NAME_FILE="${SHARED_DIR}/ocm-fvt-job-name"
CLEAN_TAR="${SHARED_DIR}/ocm-fvt-clean-state.tgz"
CLUSTER_ID_FILE="${SHARED_DIR}/cluster-id"

job_name="${OCM_FVT_JOB_NAME:-}"
if [[ -z "${job_name}" && -s "${JOB_NAME_FILE}" ]]; then
  job_name="$(tr -d '[:space:]' < "${JOB_NAME_FILE}")"
fi
if [[ -z "${job_name}" ]]; then
  echo "ERROR: OCM_FVT_JOB_NAME is required (or SHARED_DIR/ocm-fvt-job-name from the test step)" >&2
  exit 1
fi

if [[ ! -s "${CLEAN_TAR}" && ! -s "${CLUSTER_ID_FILE}" ]]; then
  echo "WARNING: no clean state tarball or cluster-id in SHARED_DIR; nothing to clean"
  exit 0
fi

podman_env_file="$(mktemp)"
trap 'rm -f "${podman_env_file}"' EXIT

{
  echo "HOME=/home/ci-user"
  echo "AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-cred"
  echo "AWS_SHARED_CREDENTIALS_FILE_QE=/credentials/aws-cred"
  echo "AWS_SHARED_CREDENTIALS_FILE_QE_2=/credentials/aws-cred"
  echo "GCP_SHARED_CREDENTIALS_FILE=/credentials/gcp-cred"
  echo "SHARED_VPC_AWS_SHARED_CREDENTIALS_FILE=/credentials/aws-shared-vpc-credentials"
  echo "JOB_LINK=https://prow.ci.openshift.org/view/gs/test-platform-results-public/logs/${JOB_NAME:-unknown}/${BUILD_ID:-unknown}"
} >> "${podman_env_file}"

if [[ -n "${OCM_FVT_OCM_ENV:-}" ]]; then
  echo "OCM_ENV=${OCM_FVT_OCM_ENV}" >> "${podman_env_file}"
fi

# Extra envs from the periodic (AWS ocp5 creds, etc.) — same as the test step.
if [[ -n "${OCM_FVT_EXTRA_ENVS:-}" ]]; then
  while IFS= read -r line; do
    [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    echo "${line}" >> "${podman_env_file}"
  done <<< "${OCM_FVT_EXTRA_ENVS}"
fi

cred_sources='source /usr/local/cs-qe-credentials/ocm-tokens'
env -i bash --norc --noprofile -c "
  ${cred_sources}
  env | grep -v '^_='
" >> "${podman_env_file}"

if [[ -f /usr/local/cs-qe-credentials/backplane_client_id && -f /usr/local/cs-qe-credentials/backplane_client_secret ]]; then
  [[ $- == *x* ]] && WAS_TRACING_SREP=true || WAS_TRACING_SREP=false
  set +x
  echo "SREP_CLIENT_ID=$(cat /usr/local/cs-qe-credentials/backplane_client_id)" >> "${podman_env_file}"
  echo "SREP_CLIENT_SECRET=$(cat /usr/local/cs-qe-credentials/backplane_client_secret)" >> "${podman_env_file}"
  $WAS_TRACING_SREP && set -x
fi

# Never defer during justClean.
grep -v -E '^(OCM_FVT_DEFER_CLEAN|GINKGO_SKIP)=' "${podman_env_file}" > "${podman_env_file}.tmp" || true
mv "${podman_env_file}.tmp" "${podman_env_file}"

ocm_fvt_output="${ARTIFACT_DIR}/ocm-fvt-clean-results"
mkdir -p "${ocm_fvt_output}"
chmod 1777 "${ocm_fvt_output}"

if [[ -s "${CLEAN_TAR}" ]]; then
  echo "Restoring clean state from ${CLEAN_TAR}"
  # Drop archived ownership/mode so the justClean container can unlink cluster.ini
  # (podman-written files often arrive as root/0600 and fail with permission denied).
  tar --no-same-owner --no-same-permissions -xzf "${CLEAN_TAR}" -C "${ocm_fvt_output}"
  chmod -R u+rwX "${ocm_fvt_output}" 2>/dev/null || true
  # Keep a copy under this step's artifacts for post-mortem (SHARED_DIR is not uploaded).
  cp -f "${CLEAN_TAR}" "${ARTIFACT_DIR}/ocm-fvt-clean-state.tgz" 2>/dev/null || true
else
  echo "WARNING: ${CLEAN_TAR} missing; justClean may no-op without cluster.ini"
fi

podman_args=(
  --authfile /usr/local/cs-qe-credentials/.dockerconfigjson
  --env-file "${podman_env_file}"
  "-v" "/usr/local/cs-qe-credentials:/credentials:ro,z"
  "-v" "${ocm_fvt_output}:/ocm-backend-tests/output:z"
  --rm
)

if [[ "${OCM_FVT_GCP_CREDS:-false}" == "true" ]]; then
  podman_args+=(
    "-v" "/usr/local/cs-qe-credentials/osd-ccs-admin.json:/home/ci-user/.gcp/osd-ccs-admin.json:ro,z"
  )
fi

echo "=== ocmci image digest ==="
podman pull --authfile /usr/local/cs-qe-credentials/.dockerconfigjson \
  quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests:latest
podman image inspect --format '{{.Digest}}' \
  quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests:latest \
  || true
echo "=========================="

echo "Running ocmtest justClean for job ${job_name}"
[[ $- == *x* ]] && WAS_TRACING_RUN=true || WAS_TRACING_RUN=false
set +x
podman run \
  "${podman_args[@]}" \
  quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests:latest \
  ocmtest test --service "${OCM_FVT_SERVICE:-cms}" --job "${job_name}" --justClean
$WAS_TRACING_RUN && set -x

echo "ocm-fvt clean finished"
