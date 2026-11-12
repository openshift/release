#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Apply Gangway override before any use of OCM_FVT_EXTRA_ENVS.
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_OCM_FVT_EXTRA_ENVS:-}" ]]; then
  echo "Applying Gangway override: OCM_FVT_EXTRA_ENVS (from MULTISTAGE_PARAM_OVERRIDE_OCM_FVT_EXTRA_ENVS)"
  export OCM_FVT_EXTRA_ENVS="${MULTISTAGE_PARAM_OVERRIDE_OCM_FVT_EXTRA_ENVS}"
fi

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
ocm_fvt_workdir=""

# The raw container output is private to this step and should not outlive it. Every
# exit path tries to remove it, after publication has already copied the collector-owned
# results into ARTIFACT_DIR, so the published copies are never touched. The removal is
# best effort rather than guaranteed: see the note on ownership below.
#
# Every command here is guarded, and the handler returns success: under errexit a
# failing command inside an EXIT trap both skips the rest of the handler and replaces
# the script's exit status, which must stay the one justClean returned.
# shellcheck disable=SC2317  # the body runs from the EXIT trap installed below
cleanup_ocm_fvt_clean() {
  rm -f "${podman_env_file}" 2>/dev/null || true
  # Only ever a directory this step created: the helper's staging directory
  # (.ocm-fvt-*) or a /tmp fallback (ocm-fvt-clean.*). The name check keeps a helper
  # that ever returned something else - ARTIFACT_DIR above all - out of the rm below.
  local workdir="${ocm_fvt_workdir:-}"
  if [[ -n "${workdir}" && ! -L "${workdir}" && -d "${workdir}" ]] &&
     [[ "${workdir##*/}" == .ocm-fvt-* || "${workdir##*/}" == ocm-fvt-clean.* ]]; then
    # The container leaves read-only result directories behind, so restore the owner
    # write bit first. Both steps are best effort, and neither is allowed to fail the
    # step: when the chown above did not apply, the tree still belongs to the container
    # user, an unprivileged step user can remove none of it, and the whole staging
    # directory survives here - private, mode 0700 and outside ARTIFACT_DIR - until the
    # pod's storage is discarded with the pod.
    chmod -R u+rwX -- "${workdir}" 2>/dev/null || true
    rm -rf -- "${workdir}" 2>/dev/null || true
  fi
  return 0
}

trap cleanup_ocm_fvt_clean EXIT

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

OCMCI_IMAGE="quay.io/redhat-services-prod/rosa-tenant/rosa-backend-tests/rosa-backend-tests:latest"

echo "=== ocmci image digest ==="
podman pull --authfile /usr/local/cs-qe-credentials/.dockerconfigjson "${OCMCI_IMAGE}"
podman image inspect --format '{{.Digest}}' "${OCMCI_IMAGE}" || true
echo "=========================="

# Image USER is ci-user (uid 998). Host step UID usually differs; tear_down's
# os.RemoveAll(profileDir) must be able to unlink cluster.ini as that uid.
img_uid="$(podman run --rm --entrypoint id "${OCMCI_IMAGE}" -u 2>/dev/null || true)"
img_uid="${img_uid:-998}"
echo "justClean container uid=${img_uid}"

# The podman output tree is written by the image user (ci-user), not by this
# step's user. Exposing it directly under ARTIFACT_DIR makes the Prow sidecar
# censor fail on every container-owned directory it cannot write into
# ("could not create temporary file for censoring .../tmp-censor..."), so the
# raw tree is staged privately next to ARTIFACT_DIR and collector-owned copies
# are published afterwards by the helper installed by rosa-e2e-ocm-fvt-prepare.
ocm_fvt_helpers="${SHARED_DIR}/ocm-fvt-artifacts.py"
if [[ -f "${ocm_fvt_helpers}" && ! -L "${ocm_fvt_helpers}" ]]; then
  if ! ocm_fvt_workdir="$(python3 "${ocm_fvt_helpers}" stage "${ARTIFACT_DIR}" 2>/dev/null)" ||
     [[ ! -d "${ocm_fvt_workdir}" ]]; then
    ocm_fvt_workdir=""
    echo "WARNING: failed to stage private ocm-fvt clean output; results stay unpublished"
  fi
else
  echo "WARNING: ocm-fvt artifact helpers were not prepared; results stay unpublished"
fi

# Cleanup itself must still run when artifacts cannot be published: a private
# fallback keeps the container output out of ARTIFACT_DIR either way, and never
# aborts the step before justClean has had a chance to delete the cluster.
if [[ -n "${ocm_fvt_workdir}" ]]; then
  publish_clean_results=true
else
  publish_clean_results=false
  # mktemp -d creates the directory itself, so it cannot be redirected. When it is
  # unavailable, fall back to `mkdir` *without* -p: plain mkdir creates the path or
  # fails, and never accepts one that already exists, including an existing symlink.
  # A /tmp entry planted ahead of this step can therefore cost it the fallback, but
  # can never make it chmod 0777, extract the clean-state tarball into, or bind-mount
  # a directory of someone else's choosing. Exhausting every candidate costs the output
  # mount: justClean still runs rather than the step aborting, but without the restored
  # cluster.ini it cannot delete the cluster, so that outcome is reported as an error.
  if ! ocm_fvt_workdir="$(mktemp -d /tmp/ocm-fvt-clean.XXXXXX 2>/dev/null)"; then
    ocm_fvt_workdir=""
    for attempt in 0 1 2 3 4; do
      if mkdir -m 0700 "/tmp/ocm-fvt-clean.$$.${attempt}" 2>/dev/null; then
        ocm_fvt_workdir="/tmp/ocm-fvt-clean.$$.${attempt}"
        echo "WARNING: mktemp unavailable; private clean output falls back to ${ocm_fvt_workdir}"
        break
      fi
    done
    if [[ -z "${ocm_fvt_workdir}" ]]; then
      echo "ERROR: no private fallback directory could be created; running justClean without an output mount" >&2
    fi
  fi
fi

ocm_fvt_output=""
if [[ -n "${ocm_fvt_workdir}" ]]; then
  if mkdir "${ocm_fvt_workdir}/output" 2>/dev/null; then
    ocm_fvt_output="${ocm_fvt_workdir}/output"
    # Do NOT use sticky 1777: sticky on the output dir blocks container ci-user from
    # removing host-owned profile dirs (unlinkat cluster.ini -> permission denied).
    chmod 0777 "${ocm_fvt_output}"
  else
    echo "ERROR: could not create the private output directory; running justClean without an output mount" >&2
    publish_clean_results=false
  fi
fi

if [[ -s "${CLEAN_TAR}" ]]; then
  if [[ -n "${ocm_fvt_output}" ]]; then
    echo "Restoring clean state from ${CLEAN_TAR}"
    # Drop archived ownership/mode from the test-step podman tree. A truncated or
    # corrupt tarball must not abort the step under errexit before justClean has run;
    # the extraction failure is reported and justClean is left to do what it can.
    if ! tar --no-same-owner --no-same-permissions -xzf "${CLEAN_TAR}" -C "${ocm_fvt_output}"; then
      echo "ERROR: ${CLEAN_TAR} could not be extracted; justClean may no-op without cluster.ini" >&2
    fi
    # Match image user so RemoveAll can unlink; a+rwX covers userns remap fallbacks.
    if chown -R "${img_uid}:${img_uid}" "${ocm_fvt_output}" 2>/dev/null; then
      echo "chown -R ${img_uid}:${img_uid} ${ocm_fvt_output}"
    else
      echo "WARNING: chown to ${img_uid} failed (need root?); relying on a+rwX"
    fi
    chmod -R a+rwX "${ocm_fvt_output}" 2>/dev/null || true
    chmod 0777 "${ocm_fvt_output}"
  else
    echo "WARNING: no private output mount; justClean runs without the restored cluster.ini"
  fi
  # Keep a copy under this step's artifacts for post-mortem (SHARED_DIR is not uploaded).
  cp -f "${CLEAN_TAR}" "${ARTIFACT_DIR}/ocm-fvt-clean-state.tgz" 2>/dev/null || true
else
  echo "WARNING: ${CLEAN_TAR} missing; justClean may no-op without cluster.ini"
fi

podman_args=(
  --authfile /usr/local/cs-qe-credentials/.dockerconfigjson
  --env-file "${podman_env_file}"
  "-v" "/usr/local/cs-qe-credentials:/credentials:ro,z"
  --rm
)

# Only a directory this step created itself is ever mounted into the container.
if [[ -n "${ocm_fvt_output}" ]]; then
  podman_args+=("-v" "${ocm_fvt_output}:/ocm-backend-tests/output:z")
fi

if [[ "${OCM_FVT_GCP_CREDS:-false}" == "true" ]]; then
  podman_args+=(
    "-v" "/usr/local/cs-qe-credentials/osd-ccs-admin.json:/home/ci-user/.gcp/osd-ccs-admin.json:ro,z"
  )
fi

echo "Running ocmtest justClean for job ${job_name}"
clean_exit_code=0
[[ $- == *x* ]] && WAS_TRACING_RUN=true || WAS_TRACING_RUN=false
set +x
podman run \
  "${podman_args[@]}" \
  "${OCMCI_IMAGE}" \
  ocmtest test --service "${OCM_FVT_SERVICE:-cms}" --job "${job_name}" --justClean || clean_exit_code=$?
$WAS_TRACING_RUN && set -x

if [[ "${clean_exit_code}" -eq 0 ]]; then
  echo "ocm-fvt clean finished"
else
  echo "ocm-fvt clean failed (exit ${clean_exit_code})" >&2
fi

# Publish regardless of the cleanup result: a failed justClean is exactly when
# its reports matter. Publication never overrides the cleanup exit status, and
# a failed publication leaves the raw output private rather than exposing it.
if [[ "${publish_clean_results}" == "true" ]]; then
  if ! python3 "${ocm_fvt_helpers}" publish \
    "${ocm_fvt_output}" "${ARTIFACT_DIR}" ocm-fvt-clean-results 2>/dev/null; then
    echo "WARNING: failed to publish ocm-fvt clean artifacts; raw output remains private"
  fi
fi

exit "${clean_exit_code}"
