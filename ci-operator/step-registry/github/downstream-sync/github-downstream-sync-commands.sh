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
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/installation" | jq -r .id)
GITHUB_TOKEN=$(curl -sS -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" -X POST \
    "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" | jq -r .token)
echo "✅ Received install token (ID: ${INSTALLATION_ID})"

echo "📥 Cloning repo and setting up remotes…"
# get the repo
WORKDIR="$(mktemp -d)"
cd "$WORKDIR"
git clone --single-branch --branch "${DEFAULT_BRANCH}" "https://github.com/${DOWNSTREAM_REPO}" repo
cd repo
git remote add upstream "https://github.com/${UPSTREAM_REPO}"
git fetch upstream "${DEFAULT_BRANCH}"
git fetch origin "${DEFAULT_BRANCH}"

echo "🔍 Checking for open downstream-merge PR…"
# check if a d/s merge PR is already open. This requires the PR titles to have the
# below format. As long as this automation is the one creating the PRs it will stay
# in this format. If something/someone else had created a d/s merge PR without this
# format, then we will still get a new one created with this script. Another person
# or process that uses this format is still ok and this automation will recognize it
# and exit early if there’s already an *open* d/s merge PR
OPEN_PR_NUM=$(
  curl -sS -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls?state=open&base=${DEFAULT_BRANCH}&per_page=100&sort=created&direction=desc" |
    jq -r '.[] | select(.title|test("DownStream Merge \\[[0-9]{2}-[0-9]{2}-[0-9]{4}\\]")) | .number' | head -n1
)
if [[ -n "$OPEN_PR_NUM" ]]; then
  echo "ℹ️  Found open downstream-merge PR #${OPEN_PR_NUM}; exiting."
  exit 0
fi

echo "📊 Counting new commits upstream…"
# to save on overhead we don't need to open a new d/s merge PR until we have enough commits to bring in
NEW_COMMITS=$(git rev-list origin/"${DEFAULT_BRANCH}"..upstream/"${DEFAULT_BRANCH}" --count)
echo "Found $NEW_COMMITS new commits upstream."
(( NEW_COMMITS < MIN_COMMITS )) && { echo "⚠️  Not enough commits (min=${MIN_COMMITS}); exiting."; exit 0; }

BRANCH="d/s-merge-$(date +%m-%d-%Y)"
echo "🧹 Deleting stale branch ${BRANCH}, if any…"
# if an earlier failed run left the branch behind, delete it now
curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X DELETE \
  "https://api.github.com/repos/${DOWNSTREAM_REPO}/git/refs/heads/${BRANCH}" || true

echo "🌿 Creating merge branch ${BRANCH} and merging…"
# if we made it this far, we can create the merge and push the PR
git checkout -b "$BRANCH" origin/"${DEFAULT_BRANCH}"
# if there happens to be a merge conflict we can still push it and create a PR...
if ! git merge "upstream/${DEFAULT_BRANCH}"; then
  echo "⚠️  Merge conflict detected"
  git add -A
  git commit -m "Merge upstream/${DEFAULT_BRANCH} into ${DEFAULT_BRANCH} with conflicts ($(date +%m-%d-%Y))"
  CONFLICT=true
fi

echo "📤 Pushing branch to origin…"
git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${DOWNSTREAM_REPO}"
git push origin "$BRANCH"

echo "✏️  Opening Pull Request…"
PR_TITLE="NO-JIRA: DownStream Merge [$(date +%m-%d-%Y)]"
PR_BODY="Automated merge of upstream/${DEFAULT_BRANCH} → ${DEFAULT_BRANCH}."
# Build the PR JSON $PAYLOAD
PAYLOAD=$(
  jq -nc \
    --arg title "$PR_TITLE" \
    --arg head  "$BRANCH" \
    --arg base  "$DEFAULT_BRANCH" \
    --arg body  "$PR_BODY" \
    '{title: $title, head: $head, base: $base, body: $body}'
)
PR_NUM=$(
  curl -sS \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls" \
  | jq -r .number
)
if [[ -z "$PR_NUM" || "$PR_NUM" == "null" ]]; then
  echo "❌ ERROR: failed to create PR" >&2
  exit 1
fi
echo "🔖 Opened PR #${PR_NUM}"

echo "💬 Posting /ok-to-test and payload commands…"
# mark it /ok-to-test and start payload jobs
curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X POST \
     -d "{\"body\":\"/ok-to-test\n/payload ${RELEASE} ci blocking\n/payload ${RELEASE} nightly blocking\"}" \
     "https://api.github.com/repos/${DOWNSTREAM_REPO}/issues/${PR_NUM}/comments"

if [[ "${CONFLICT:-false}" == "true" ]]; then
  echo "🚨 Prepending MERGE CONFLICT! and holding PR #${PR_NUM}"
  NEW_TITLE="MERGE CONFLICT! ${PR_TITLE}"
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X PATCH -d "{\"title\":\"${NEW_TITLE}\"}" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls/${PR_NUM}"
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X POST -d '{"body":"/hold\nneeds conflict resolution"}' \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/issues/${PR_NUM}/comments"
  echo "⚠️  PR #${PR_NUM} held for manual resolution"
  exit 1
fi

echo "✅ Merge succeeded; PR #${PR_NUM} created."
