#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# helper to make things more readable below
b64url() {
  openssl base64 -e \
    | tr '/+' '_-' \
    | tr -d '=' \
    | tr -d '\n'
}

echo "🔐 Generating JWT…"
# create the JWT needed to get an app install token needed for API requests
# the token is short-lived and will expire after EXP below
NOW=$(date +%s)
EXP=$((NOW + 600))
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$NOW" "$EXP" "$GITHUB_APP_ID" | b64url)
SIG_INPUT="$HEADER.$PAYLOAD"

echo "🖋 Signing JWT…"
SIGNATURE=$(
  printf '%s' "$SIG_INPUT" \
    | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_FILE" \
    | b64url
)
JWT="$HEADER.$PAYLOAD.$SIGNATURE"

echo "🔗 Exchanging JWT for installation token…"
INSTALLATION_ID=$(curl -sS -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/installation" | jq -r .id)
GITHUB_TOKEN=$(curl -sS -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" -X POST \
    "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" | jq -r .token)
echo "✅ Received install token (ID: ${INSTALLATION_ID})"

echo "📥 Cloning repo and setting up remotes…"
# get the repo
WORKDIR="$(mktemp -d)"
cd "$WORKDIR"
git clone --single-branch --branch "${SOURCE_BRANCH}" "https://github.com/${REPO}" repo
cd repo
git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPO}"
git fetch origin \
  "+refs/heads/${SOURCE_BRANCH}:refs/remotes/origin/${SOURCE_BRANCH}" \
  "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}"

TITLE_DATE=$(date +%m-%d-%Y)
BRANCH="sync-${SOURCE_BRANCH}-to-${TARGET_BRANCH}-${TITLE_DATE}"
PR_TITLE="NO-JIRA: Branch Sync ${SOURCE_BRANCH} to ${TARGET_BRANCH} [${TITLE_DATE}]"
PR_BODY="Automated branch sync: ${SOURCE_BRANCH} to ${TARGET_BRANCH}."

# exit if no new commits are available to sync
NEW_COMMITS=$(git rev-list "origin/${TARGET_BRANCH}..origin/${SOURCE_BRANCH}" --count)
(( NEW_COMMITS == 0 )) && { echo "No changes to sync; exiting."; exit 0; }

# exit if there is already an open PR for branch sync
OPEN=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" \
  "https://api.github.com/repos/${REPO}/pulls?state=open&base=${TARGET_BRANCH}&per_page=100" \
  | jq -r --arg tb "$TARGET_BRANCH" --arg sb "$SOURCE_BRANCH" '
  .[] | select(.title | test("Branch Sync " + $sb + " to " + $tb + " \\[[0-9]{2}-[0-9]{2}-[0-9]{4}\\]")) | .number' \
  | head -n1
)

if [[ -n "$OPEN" ]]; then
  echo "Open branch-sync PR #$OPEN; exiting."
  exit 0
fi

echo "🧹 Deleting stale branch ${BRANCH}, if any…"
# if an earlier failed run left the branch behind, delete it now
curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X DELETE \
  "https://api.github.com/repos/${REPO}/git/refs/heads/${BRANCH}" || true

# create branch off TARGET, merge SOURCE with -X theirs
git checkout -b "$BRANCH" "origin/${TARGET_BRANCH}"
CONFLICT=false
if ! git merge -X theirs "origin/${SOURCE_BRANCH}" --no-edit; then
  echo "Merge conflict (even with -X theirs)."
  git add -A
  git commit -m "Sync ${SOURCE_BRANCH} to ${TARGET_BRANCH} with conflicts (${TITLE_DATE})"
  CONFLICT=true
fi

# push and open PR (draft if conflict)
git push origin "$BRANCH"
DRAFT=$( [[ "${CONFLICT:-false}" == "true" ]] && echo true || echo false )
PAYLOAD=$(
  jq -nc \
    --arg title     "$PR_TITLE" \
    --arg head      "$BRANCH" \
    --arg base      "$TARGET_BRANCH" \
    --arg body      "$PR_BODY" \
    --argjson draft "$DRAFT" \
    '{title: $title, head: $head, base: $base, body: $body, draft: $draft}'
)

# for debug purposes, let's show this PAYLOAD in the job logs
echo "PR CREATION PAYLOAD: ${PAYLOAD}"

PR_NUM=$(
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" \
  -H "Content-Type: application/json" \
  -X POST \
  -d "$PAYLOAD" "https://api.github.com/repos/${REPO}/pulls" \
  | jq -r .number
)
if [[ -z "$PR_NUM" || "$PR_NUM" == "null" ]]; then
  echo "❌ ERROR: failed to create PR" >&2
  exit 1
fi
echo "🔖 Opened PR #${PR_NUM}"

if $CONFLICT; then
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X PATCH \
    -d "{\"title\":\"MERGE CONFLICT! ${PR_TITLE}\"}" \
    "https://api.github.com/repos/${REPO}/pulls/${PR_NUM}"
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X POST \
    -d '{"body":"/hold\nneeds conflict resolution"}' \
    "https://api.github.com/repos/${REPO}/issues/${PR_NUM}/comments"
  exit 1
else
  CI_BRANCH=${TARGET_BRANCH#release-}
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X POST \
    -d "{\"body\":\"/ok-to-test\n/payload ${CI_BRANCH} ci blocking\n/payload ${CI_BRANCH} nightly blocking\"}" \
    "https://api.github.com/repos/${REPO}/issues/${PR_NUM}/comments"
fi
