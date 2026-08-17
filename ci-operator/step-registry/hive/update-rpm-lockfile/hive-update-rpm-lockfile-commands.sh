#!/bin/bash

set -euo pipefail

# Never enable xtrace: this script handles subscription and GitHub credentials.
set +o xtrace

log() { echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] $*"; }
info() { log "[info] $*"; }
error() { log "[error] $*"; exit 1; }

LOCKFILE_DIR="hack/hermetic"
LOCKFILE_PATH="${LOCKFILE_DIR}/rpms.lock.yaml"
REPOFILE_PATH="${LOCKFILE_DIR}/redhat.repo"
INPUT_PATH="${LOCKFILE_DIR}/rpms.in.yaml"
PR_TITLE="[Automated] Update RPM lockfile for hermetic builds"
BRANCH_NAME="automated-rpm-lockfile-update"
GITHUB_API="https://api.github.com"
FORK_REMOTE="fork"

[[ -d .git ]] || error "not in a git repository"
[[ -f "${INPUT_PATH}" ]] || error "missing ${INPUT_PATH}"
[[ -f "${REPOFILE_PATH}" ]] || error "missing ${REPOFILE_PATH}"
[[ -f "${LOCKFILE_PATH}" ]] || error "missing ${LOCKFILE_PATH}"

# --- Credentials -----------------------------------------------------------

[[ -d "${ACTIVATION_KEY_DIR}" ]] || error "activation key directory not found: ${ACTIVATION_KEY_DIR}"
ORG_FILE="${ACTIVATION_KEY_DIR}/org"
if [[ -f "${ACTIVATION_KEY_DIR}/activationkey" ]]; then
  KEY_FILE="${ACTIVATION_KEY_DIR}/activationkey"
elif [[ -f "${ACTIVATION_KEY_DIR}/activation-key" ]]; then
  KEY_FILE="${ACTIVATION_KEY_DIR}/activation-key"
else
  error "activation key file not found in ${ACTIVATION_KEY_DIR} (expected activationkey or activation-key)"
fi
[[ -f "${ORG_FILE}" ]] || error "org file not found: ${ORG_FILE}"

[[ -f "${GITHUB_TOKEN_PATH}" ]] || error "GitHub token file not found: ${GITHUB_TOKEN_PATH}"
GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
[[ -n "${GITHUB_TOKEN}" ]] || error "GitHub token file is empty"

# --- Tooling ---------------------------------------------------------------

export SMDEV_CONTAINER_OFF=1
# /etc/rhsm-host is pre-removed in the lockfile-tools image; this is a safety guard
if [[ -e /etc/rhsm-host ]]; then
  unlink /etc/rhsm-host || true
fi

info "registering with subscription-manager"
registered=false
for attempt in 1 2 3; do
  if subscription-manager register --force \
      --org "$(cat "${ORG_FILE}")" \
      --activationkey "$(cat "${KEY_FILE}")"; then
    registered=true
    break
  fi
  info "subscription-manager register failed (attempt ${attempt}/3), retrying"
  sleep 5
done
[[ "${registered}" == true ]] || error "subscription-manager register failed after 3 attempts"

cleanup() {
  subscription-manager unregister >/dev/null 2>&1 || true
}
trap cleanup EXIT

info "patching entitlement certificate paths in ${REPOFILE_PATH} (not committed)"
shopt -s nullglob
keys=(/etc/pki/entitlement/*-key.pem)
shopt -u nullglob
[[ ${#keys[@]} -gt 0 ]] || error "no entitlement key found under /etc/pki/entitlement"
ssl_key="${keys[0]}"
ssl_cert="${ssl_key/-key.pem/.pem}"
[[ -f "${ssl_cert}" ]] || error "entitlement cert not found next to ${ssl_key}"
sed -i -E \
  -e "s|^sslclientkey = .*|sslclientkey = ${ssl_key}|" \
  -e "s|^sslclientcert = .*|sslclientcert = ${ssl_cert}|" \
  "${REPOFILE_PATH}"

info "installing rpm-lockfile-prototype"
tag=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" \
  "${GITHUB_API}/repos/konflux-ci/rpm-lockfile-prototype/releases/latest" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")
[[ -n "${tag}" ]] || error "failed to resolve latest rpm-lockfile-prototype tag"
python3 -m pip install --user \
  "https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/tags/${tag}.tar.gz"
export PATH="${HOME}/.local/bin:${PATH}"
command -v rpm-lockfile-prototype >/dev/null || error "rpm-lockfile-prototype not on PATH"

info "generating ${LOCKFILE_PATH} with rpm-lockfile-prototype ${tag} (bare)"
(
  cd "${LOCKFILE_DIR}"
  rpm-lockfile-prototype --bare --outfile rpms.lock.yaml rpms.in.yaml
)

# Discard repo-file path edits; only the lockfile may be proposed.
git checkout -- "${REPOFILE_PATH}"

if [[ -n "${ARTIFACT_DIR:-}" ]]; then
  cp "${LOCKFILE_PATH}" "${ARTIFACT_DIR}/rpms.lock.yaml"
fi

if git diff --quiet -- "${LOCKFILE_PATH}"; then
  info "lockfile is already up to date"
  exit 0
fi

info "lockfile changed; preparing pull request"
git config user.name "${GITHUB_PR_USER}"
git config user.email "${GITHUB_PR_EMAIL}"
git config credential.helper "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN}; }; f"

github_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  if [[ -n "${data}" ]]; then
    curl -sS -X "${method}" \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" \
      -d "${data}" \
      "${GITHUB_API}${endpoint}"
  else
    curl -sS -X "${method}" \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GITHUB_API}${endpoint}"
  fi
}

fork_http=$(curl -sS -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API}/repos/${GITHUB_PR_USER}/${GITHUB_REPO_NAME}")
if [[ "${fork_http}" != "200" ]]; then
  info "creating fork ${GITHUB_PR_USER}/${GITHUB_REPO_NAME}"
  github_api POST "/repos/${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}/forks" '{"default_branch_only":true}' >/dev/null
  for _ in $(seq 1 12); do
    fork_http=$(curl -sS -o /dev/null -w "%{http_code}" \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${GITHUB_API}/repos/${GITHUB_PR_USER}/${GITHUB_REPO_NAME}")
    [[ "${fork_http}" == "200" ]] && break
    sleep 10
  done
  [[ "${fork_http}" == "200" ]] || error "fork ${GITHUB_PR_USER}/${GITHUB_REPO_NAME} not ready"
fi

git remote add "${FORK_REMOTE}" "https://github.com/${GITHUB_PR_USER}/${GITHUB_REPO_NAME}.git" 2>/dev/null || \
  git remote set-url "${FORK_REMOTE}" "https://github.com/${GITHUB_PR_USER}/${GITHUB_REPO_NAME}.git"

existing_pr=$(github_api GET "/repos/${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}/pulls?state=open&per_page=100" | python3 -c "
import json, sys
prs = json.load(sys.stdin)
if not isinstance(prs, list):
    sys.exit(0)
title = '''${PR_TITLE}'''
user = '''${GITHUB_PR_USER}'''
for pr in prs:
    if pr.get('title') == title and pr.get('user', {}).get('login') == user:
        print(f\"{pr['number']}|{pr['head']['ref']}|{pr['html_url']}\")
        break
")

git add "${LOCKFILE_PATH}"
if [[ -n "${existing_pr}" ]]; then
  existing_number=$(echo "${existing_pr}" | cut -d'|' -f1)
  existing_branch=$(echo "${existing_pr}" | cut -d'|' -f2)
  existing_url=$(echo "${existing_pr}" | cut -d'|' -f3)
  info "found existing PR #${existing_number} on ${existing_branch}"
  git fetch "${FORK_REMOTE}" "${existing_branch}"
  if git diff --staged --quiet "${FORK_REMOTE}/${existing_branch}" -- "${LOCKFILE_PATH}"; then
    info "existing PR already has the same lockfile: ${existing_url}"
    exit 0
  fi
  BRANCH_NAME="${existing_branch}"
fi

git checkout -B "${BRANCH_NAME}"
git commit -m "Update RPM lockfile for hermetic builds

Generated by rpm-lockfile-prototype from hack/hermetic/rpms.in.yaml.
"

info "pushing ${BRANCH_NAME} to ${GITHUB_PR_USER}/${GITHUB_REPO_NAME}"
git push --force "${FORK_REMOTE}" "${BRANCH_NAME}"

if [[ -n "${existing_pr}" ]]; then
  info "updated existing PR: ${existing_url}"
  exit 0
fi

diff_stat=$(git diff HEAD~1 --stat -- "${LOCKFILE_PATH}")
pr_body=$(cat <<EOF
## Summary
This automated PR regenerates \`hack/hermetic/rpms.lock.yaml\` for hive hermetic builds using \`rpm-lockfile-prototype\` in bare mode. \`redhat.repo\` and \`rpms.in.yaml\` are not modified.

## File changes
\`\`\`
${diff_stat}
\`\`\`

---
**Generated by:** ${JOB_NAME:-hive-update-rpm-lockfile}
**Generated at:** $(date +%Y-%m-%dT%H:%M:%S%z)
EOF
)

export PR_TITLE PR_HEAD="${GITHUB_PR_USER}:${BRANCH_NAME}" PR_BASE="${GITHUB_REPO_BRANCH}" PR_BODY="${pr_body}"
pr_json=$(python3 -c "
import json, os
print(json.dumps({
    'title': os.environ['PR_TITLE'],
    'head': os.environ['PR_HEAD'],
    'base': os.environ['PR_BASE'],
    'body': os.environ['PR_BODY'],
}))
")

info "creating pull request"
pr_response=$(github_api POST "/repos/${GITHUB_REPO_ORG}/${GITHUB_REPO_NAME}/pulls" "${pr_json}")
pr_url=$(echo "${pr_response}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('html_url', ''))
")
if [[ -z "${pr_url}" ]]; then
  err=$(echo "${pr_response}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('message', data.get('errors', 'unknown error')))
" 2>/dev/null || echo "unknown error")
  error "failed to create PR: ${err}"
fi
info "created PR: ${pr_url}"
