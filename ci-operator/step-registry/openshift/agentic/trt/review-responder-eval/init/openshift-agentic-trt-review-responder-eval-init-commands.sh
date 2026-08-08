#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder Eval Init ==="

CASE_DIR="/opt/ai-helpers/evals/review-responder/cases"
CASE_NAME="case-001-trt-2660-null-explanations"
CASE_SRC="${CASE_DIR}/${CASE_NAME}"

[[ -d "${CASE_SRC}" ]] || { echo "ERROR: Case directory not found: ${CASE_SRC}"; exit 1; }

# --- Read case config ---
yaml_val() { grep "^${1}:" "$2" | cut -d' ' -f2-; }

INPUT_FILE="${CASE_SRC}/input.yaml"
JIRA_ISSUE_KEY=$(yaml_val jira_key "${INPUT_FILE}")
BASE_BRANCH=$(yaml_val base_branch "${INPUT_FILE}")
HEAD_BRANCH=$(yaml_val head_branch "${INPUT_FILE}")

echo "Case: ${CASE_NAME}"
echo "  JIRA: ${JIRA_ISSUE_KEY} | Base: ${BASE_BRANCH} | Head: ${HEAD_BRANCH}"

# --- Read tokens ---
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN
git config --global credential.helper '!f() { echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f'

# --- Create timestamped eval branch from head ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
EVAL_BRANCH="${HEAD_BRANCH}-eval-${TIMESTAMP}"
echo "Creating eval branch: ${EVAL_BRANCH}"

git clone "https://github.com/${UPSTREAM_REPO}.git" /tmp/eval-repo
cd /tmp/eval-repo
git config user.name "openshift-trt"
git config user.email "openshift-trt@redhat.com"

git fetch origin "${HEAD_BRANCH}" "${BASE_BRANCH}"
git checkout -b "${EVAL_BRANCH}" "origin/${HEAD_BRANCH}"
git push origin "${EVAL_BRANCH}"

# Persist branch metadata immediately so cleanup can run if later steps fail
echo "${EVAL_BRANCH}" > "${SHARED_DIR}/eval-head-branch"
echo "${BASE_BRANCH}" > "${SHARED_DIR}/eval-base-branch"

# --- Create PR ---
JIRA_SUMMARY=$(jq -r '.fields.summary // "eval"' "${CASE_SRC}/jira-issue.json" 2>/dev/null || echo "eval")
PR_TITLE="${JIRA_ISSUE_KEY}: ${JIRA_SUMMARY} [eval]"

PR_URL=$(gh pr create \
    --repo "${UPSTREAM_REPO}" \
    --head "${EVAL_BRANCH}" \
    --base "${BASE_BRANCH}" \
    --title "$(echo "${PR_TITLE}" | head -c 250)" \
    --body "Review-responder eval PR. Automated — do not merge." \
    2>&1) || {
    echo "ERROR: Failed to create PR: ${PR_URL}"
    exit 1
}

PR_NUM=$(echo "${PR_URL}" | grep -o '[0-9]*$')
echo "PR created: ${PR_URL} (#${PR_NUM})"
echo "${PR_NUM}" > "${SHARED_DIR}/pr-number"

# Record the fixture HEAD SHA so the judge can diff only responder changes
FIXTURE_HEAD_SHA=$(git rev-parse HEAD)
echo "${FIXTURE_HEAD_SHA}" > "${SHARED_DIR}/fixture-head-sha"

# --- Post seeded comments ---
COMMENTS_FILE="${CASE_SRC}/comments.json"
[[ -f "${COMMENTS_FILE}" ]] || { echo "ERROR: comments.json not found"; exit 1; }

COMMENT_MAP="{"
COMMENT_COUNT=$(jq 'length' "${COMMENTS_FILE}")
POSTED=0

for i in $(seq 0 $(( COMMENT_COUNT - 1 ))); do
    COMMENT_ID=$(jq -r ".[$i].id" "${COMMENTS_FILE}")
    COMMENT_TYPE=$(jq -r ".[$i].type" "${COMMENTS_FILE}")
    COMMENT_BODY=$(jq -r ".[$i].body" "${COMMENTS_FILE}")

    if [[ "${COMMENT_TYPE}" != "issue_comment" ]]; then
        echo "  Unsupported comment type '${COMMENT_TYPE}' for ${COMMENT_ID}, posting as issue comment"
    fi

    GH_COMMENT_ID=$(gh api "repos/${UPSTREAM_REPO}/issues/${PR_NUM}/comments" \
        -f body="${COMMENT_BODY}" \
        --jq '.id' 2>&1) || {
        echo "ERROR: Failed to post comment ${COMMENT_ID}: ${GH_COMMENT_ID}"
        exit 1
    }

    echo "  Posted ${COMMENT_ID} (type=${COMMENT_TYPE}) -> GitHub comment ${GH_COMMENT_ID}"

    [[ "${POSTED}" -gt 0 ]] && COMMENT_MAP="${COMMENT_MAP},"
    COMMENT_MAP="${COMMENT_MAP}\"${COMMENT_ID}\":${GH_COMMENT_ID}"
    POSTED=$(( POSTED + 1 ))
done
COMMENT_MAP="${COMMENT_MAP}}"

# --- Write remaining metadata to SHARED_DIR ---
echo "${JIRA_ISSUE_KEY}" > "${SHARED_DIR}/jira-issue-key"
echo "${COMMENT_MAP}" > "${SHARED_DIR}/comment-map.json"
cp "${COMMENTS_FILE}" "${SHARED_DIR}/comments.json"
cp "${CASE_SRC}/jira-issue.json" "${SHARED_DIR}/jira-issue.json"

echo "=== TRT Review Responder Eval Init Complete ==="
