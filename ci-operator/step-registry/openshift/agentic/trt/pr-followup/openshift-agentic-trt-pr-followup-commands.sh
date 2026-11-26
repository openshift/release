#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT PR Followup ==="

[[ -f "${SHARED_DIR}/github-app-auth.sh" ]] || {
    echo "ERROR: ${SHARED_DIR}/github-app-auth.sh not found — github-app-auth step must run first"
    exit 1
}
# shellcheck source=/dev/null
source "${SHARED_DIR}/github-app-auth.sh"
load_github_tokens
configure_github_git_credentials

JIRA_ISSUE_KEY=$(cat "${SHARED_DIR}/jira-issue-key")

# --- Select PR ---
PR_NUMBER="${PR_NUMBER:-}"
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_PR_NUMBER:-}" ]]; then
    echo "Applying Gangway override: PR_NUMBER=${MULTISTAGE_PARAM_OVERRIDE_PR_NUMBER}"
    PR_NUMBER="${MULTISTAGE_PARAM_OVERRIDE_PR_NUMBER}"
fi

if [[ -n "${PR_NUMBER}" ]]; then
    if [[ ! "${PR_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: PR_NUMBER must be a positive integer."
        exit 1
    fi
    PR_NUM="${PR_NUMBER}"
    echo "Looking up explicit PR #${PR_NUM} in ${UPSTREAM_REPO}..."
else
    echo "Searching for PR associated with ${JIRA_ISSUE_KEY}..."
    PR_LIST=$(gh pr list --repo "${UPSTREAM_REPO}" --state open --search "${JIRA_ISSUE_KEY}" --json number --limit 5 2>/dev/null || echo "[]")
    if [[ $(jq 'length' <<< "${PR_LIST}") -eq 0 ]]; then
        echo "No open PR found. Searching closed PRs..."
        PR_LIST=$(gh pr list --repo "${UPSTREAM_REPO}" --state closed --search "${JIRA_ISSUE_KEY}" --json number --limit 5 2>/dev/null || echo "[]")
    fi
    if ! PR_NUM=$(jq -er '.[0].number | select(type == "number" and . > 0)' <<< "${PR_LIST}"); then
        echo "ERROR: No PR found for ${JIRA_ISSUE_KEY}."
        exit 1
    fi
fi

# Resolve every selection through the configured upstream. An explicit lookup
# failure is terminal: it must never fall back to a Jira-key search.
if ! PR_JSON=$(gh pr view "${PR_NUM}" --repo "${UPSTREAM_REPO}" \
    --json number,state,title,url,headRefName,headRefOid,headRepository,headRepositoryOwner 2>/dev/null); then
    echo "ERROR: Unable to read PR #${PR_NUM} from ${UPSTREAM_REPO}."
    exit 1
fi
if ! PR_METADATA_NUM=$(jq -er '.number | select(type == "number" and . > 0)' <<< "${PR_JSON}") || \
   ! PR_URL=$(jq -er '.url | strings | select(length > 0)' <<< "${PR_JSON}") || \
   ! PR_STATE=$(jq -er '.state | strings | select(length > 0)' <<< "${PR_JSON}") || \
   ! PR_BRANCH=$(jq -er '.headRefName | strings | select(length > 0)' <<< "${PR_JSON}") || \
   ! PR_HEAD_SHA=$(jq -er '.headRefOid | strings | select(test("^[0-9a-f]{40}$"))' <<< "${PR_JSON}") || \
   ! PR_HEAD_OWNER=$(jq -er '.headRepositoryOwner.login | strings | select(length > 0)' <<< "${PR_JSON}") || \
   ! PR_HEAD_REPO=$(jq -er '.headRepository.name | strings | select(length > 0)' <<< "${PR_JSON}"); then
    echo "ERROR: PR #${PR_NUM} metadata is incomplete or invalid."
    exit 1
fi

if [[ ! "${UPSTREAM_REPO}" =~ ^[^/]+/[^/]+$ ]] || \
   [[ "${PR_METADATA_NUM}" != "${PR_NUM}" ]] || \
   [[ "${PR_URL,,}" != "https://github.com/${UPSTREAM_REPO,,}/pull/${PR_NUM}" ]]; then
    echo "ERROR: PR #${PR_NUM} metadata does not match the configured upstream."
    exit 1
fi
if [[ ! "${FORK_REPO}" =~ ^[^/]+/[^/]+$ ]] || \
   [[ "${PR_HEAD_OWNER,,}/${PR_HEAD_REPO,,}" != "${FORK_REPO,,}" ]]; then
    echo "ERROR: PR #${PR_NUM} head repository does not match the configured fork."
    exit 1
fi

echo "Selected PR #${PR_NUM} (${PR_STATE}) | Branch: ${PR_BRANCH}"

# --- Check out PR branch ---
WORKDIR="${WORKDIR:-/workspace}"
cd "${WORKDIR}"
git config user.name "openshift-trt"
git config user.email "openshift-trt@redhat.com"
git remote add fork "https://github.com/${FORK_REPO}.git"

if ! git check-ref-format --branch "${PR_BRANCH}" >/dev/null 2>&1; then
    echo "ERROR: PR #${PR_NUM} head branch is invalid."
    exit 1
fi
if [[ $(git remote get-url --all fork 2>/dev/null || true) != "https://github.com/${FORK_REPO}.git" ]] || \
   [[ $(git remote get-url --push --all fork 2>/dev/null || true) != "https://github.com/${FORK_REPO}.git" ]]; then
    echo "ERROR: fork remote does not match the configured fork."
    exit 1
fi
if ! WORKTREE_STATUS=$(git status --porcelain=v1 --untracked-files=all); then
    echo "ERROR: unable to verify that the worktree is clean."
    exit 1
elif [[ -n "${WORKTREE_STATUS}" ]]; then
    echo "ERROR: refusing to check out the PR head with worktree changes."
    exit 1
fi

if ! git fetch --no-tags --no-recurse-submodules fork "refs/heads/${PR_BRANCH}"; then
    echo "ERROR: Unable to fetch PR #${PR_NUM} head from the configured fork."
    exit 1
fi
if ! FETCHED_HEAD=$(git rev-parse --verify 'FETCH_HEAD^{commit}') || \
   [[ "${FETCHED_HEAD}" != "${PR_HEAD_SHA}" ]]; then
    echo "ERROR: Fetched PR #${PR_NUM} head does not match its reported SHA."
    exit 1
fi

git checkout --no-recurse-submodules --no-overwrite-ignore \
    -B "${PR_BRANCH}" "${FETCHED_HEAD}"

# Persist only a fully validated, successfully checked-out selection for the
# review-responder step.
echo "${PR_NUM}" > "${SHARED_DIR}/pr-number"

echo "=== TRT PR Followup Complete ==="
