#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

CREDS_DIR=/usr/local/osdfm-qe-credentials
GITHUB_CREDS_DIR=/usr/local/github-credentials
ROSA_BACKEND_TESTS_REF=${ROSA_BACKEND_TESTS_REF:-master}

# Post steps always run; only promote if the OSDFM integration test recorded success.
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

if [[ ! -s "${GITHUB_CREDS_DIR}/oauth" ]]; then
  echo "ERROR: ${GITHUB_CREDS_DIR}/oauth is missing or empty; cannot clone private GitHub repos" >&2
  exit 1
fi

# Keep xtrace off while the GitHub token is in git config / env.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

export OSDFM_GITLAB_TOKEN
export OSDFM_WEBHOOK_URL
OSDFM_GITLAB_TOKEN=$(<"${CREDS_DIR}/osdfm_gitlab_token")
OSDFM_WEBHOOK_URL=$(<"${CREDS_DIR}/osdfm_webhook_url")

# rosa-e2e is public, so mount the git-cloner token and put git config in a
# private HOME. credential.helper then authenticates this clone and osdfm_release.sh.
export HOME
HOME=$(mktemp -d)
trap 'rm -rf "${HOME}"' EXIT
workdir=$(mktemp -d)
trap 'rm -rf "${workdir}" "${HOME}"' EXIT
GITHUB_TOKEN=$(tr -d '[:space:]' < "${GITHUB_CREDS_DIR}/oauth")
if [[ -z "${GITHUB_TOKEN}" ]]; then
  echo "ERROR: ${GITHUB_CREDS_DIR}/oauth is empty" >&2
  exit 1
fi
git config --global credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN}; }; f"
# --add: a second insteadOf on the same key otherwise overwrites the first.
git config --global url."https://github.com/".insteadOf "git@github.com:"
git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"

echo "Cloning openshift-online/rosa-backend-tests (ref ${ROSA_BACKEND_TESTS_REF})"
unset GIT_ASKPASS || true
GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "${ROSA_BACKEND_TESTS_REF}" \
  https://github.com/openshift-online/rosa-backend-tests.git \
  "${workdir}/rosa-backend-tests"

$WAS_TRACING && set -x

cd "${workdir}/rosa-backend-tests"

if [[ -n "${COMMIT_SHA:-}" ]]; then
  export COMMIT_SHA
fi

# osdfm_release.sh still embeds GitLab tokens in git remotes; keep tracing off.
set +x
./osdfm_release.sh
