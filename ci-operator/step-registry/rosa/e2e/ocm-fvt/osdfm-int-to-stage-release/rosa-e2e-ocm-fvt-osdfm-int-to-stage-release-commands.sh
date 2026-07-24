#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

CREDS_DIR=/usr/local/osdfm-qe-credentials
OCM_BACKEND_TESTS_REF=${OCM_BACKEND_TESTS_REF:-master}

# This is a post step, which ci-operator always runs regardless of whether
# the preceding test step passed or failed. Only proceed with the stage
# promotion if the OSDFM integration test explicitly reported success.
if [[ ! -f "${SHARED_DIR}/ocm-fvt-exit-code" ]]; then
  echo "WARNING: ${SHARED_DIR}/ocm-fvt-exit-code not found; cannot confirm the OSDFM integration test succeeded. Skipping stage promotion." >&2
  exit 0
fi

test_exit_code="$(<"${SHARED_DIR}/ocm-fvt-exit-code")"
if [[ "${test_exit_code}" != "0" ]]; then
  echo "Skipping OSDFM stage promotion: the OSDFM integration test failed (exit code ${test_exit_code})."
  exit 0
fi

if [[ ! -f "${CREDS_DIR}/osdfm_gitlab_token" ]]; then
  echo "ERROR: ${CREDS_DIR}/osdfm_gitlab_token not found" >&2
  exit 1
fi

if [[ ! -f "${CREDS_DIR}/osdfm_webhook_url" ]]; then
  echo "ERROR: ${CREDS_DIR}/osdfm_webhook_url not found" >&2
  exit 1
fi

# Keep xtrace off through both the credential reads and the wget below: the
# wget URL embeds an internal GitLab hostname, and we don't want either the
# tokens or that internal hostname/URL structure showing up in trace output.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

export OSDFM_GITLAB_TOKEN
export OSDFM_WEBHOOK_URL
OSDFM_GITLAB_TOKEN=$(<"${CREDS_DIR}/osdfm_gitlab_token")
OSDFM_WEBHOOK_URL=$(<"${CREDS_DIR}/osdfm_webhook_url")

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

tarball="${workdir}/ocm-backend-tests-${OCM_BACKEND_TESTS_REF}.tar.gz"
wget -q \
  "https://gitlab.cee.redhat.com/service/ocm-backend-tests/-/archive/${OCM_BACKEND_TESTS_REF}/ocm-backend-tests-${OCM_BACKEND_TESTS_REF}.tar.gz" \
  -O "${tarball}"

$WAS_TRACING && set -x

tar -zxf "${tarball}" -C "${workdir}"
cd "${workdir}/ocm-backend-tests-${OCM_BACKEND_TESTS_REF}"

if [[ -n "${COMMIT_SHA:-}" ]]; then
  export COMMIT_SHA
fi

./osdfm_release.sh
