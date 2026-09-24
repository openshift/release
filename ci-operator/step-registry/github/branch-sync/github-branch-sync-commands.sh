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

cleanup_stale_branches() {
  local had_errexit=false
  [[ $- == *e* ]] && had_errexit=true
  set +o errexit

  local deleted=0 skipped=0 failed=0
  if (( STALE_BRANCH_AGE_DAYS == 0 )); then
    echo "ℹ️  STALE_BRANCH_AGE_DAYS=0; skipping stale branch cleanup"
    $had_errexit && set -o errexit
    return
  fi

  echo "🧹 Scanning ${REPO} for stale sync-${SOURCE_BRANCH}-to-${TARGET_BRANCH} branches…"
  local current_branch="sync-${SOURCE_BRANCH}-to-${TARGET_BRANCH}-$(date +%m-%d-%Y)"
  local pattern="^sync-${SOURCE_BRANCH}-to-${TARGET_BRANCH}-[0-9]{2}-[0-9]{2}-[0-9]{4}$"
  local cutoff owner url headers resp
  cutoff=$(date -d "-${STALE_BRANCH_AGE_DAYS} days" +%s)
  owner="${REPO%%/*}"
  url="https://api.github.com/repos/${REPO}/branches?per_page=100"

  local branches=()
  while [[ -n "$url" ]]; do
    headers=$(mktemp)
    resp=$(curl -sS -D "$headers" -H "Authorization: token ${GITHUB_TOKEN}" "$url")
    if [[ -z "$resp" ]]; then
      echo "⚠️  Failed to list branches from ${url}"
      ((failed++))
      rm -f "$headers"
      break
    fi
    while IFS= read -r name; do
      [[ -n "$name" ]] && branches+=("$name")
    done < <(echo "$resp" | jq -r '.[].name' | grep -E "$pattern")
    url=$(grep -i '^link:' "$headers" | tr ',' '\n' | grep 'rel="next"' | sed -E 's/.*<([^>]+)>.*/\1/')
    rm -f "$headers"
  done

  for branch in "${branches[@]}"; do
    [[ "$branch" == "$current_branch" ]] && continue
    [[ "$branch" =~ ([0-9]{2})-([0-9]{2})-([0-9]{4})$ ]] || continue

    local branch_epoch
    branch_epoch=$(date -d "${BASH_REMATCH[3]}-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}" +%s 2>/dev/null)
    if [[ -z "$branch_epoch" ]]; then
      echo "⚠️  Could not parse date from branch ${branch}"
      ((failed++))
      continue
    fi
    (( branch_epoch >= cutoff )) && continue

    local pr_json
    pr_json=$(curl -sS -H "Authorization: token ${GITHUB_TOKEN}" \
      "https://api.github.com/repos/${REPO}/pulls?state=all&head=${owner}:${branch}&per_page=100")
    if [[ -z "$pr_json" ]]; then
      echo "⚠️  Failed to look up PRs for branch ${branch}"
      ((failed++))
      continue
    fi

    if [[ "$(echo "$pr_json" | jq -r '[.[] | select(.state=="open")] | length')" != "0" ]]; then
      echo "⏭️  Skipping ${branch}: open PR exists"
      ((skipped++))
      continue
    fi

    local reason
    reason=$(echo "$pr_json" | jq -r 'if ([.[] | select(.merged_at != null)] | length) > 0 then "merged" elif length > 0 then "closed" else "no PR" end')

    if [[ "${STALE_BRANCH_DRY_RUN}" == "true" ]]; then
      echo "🔍 [dry-run] would delete ${branch} (${reason})"
      ((skipped++))
      continue
    fi

    if curl -sS -f -H "Authorization: token ${GITHUB_TOKEN}" -X DELETE \
      "https://api.github.com/repos/${REPO}/git/refs/heads/${branch}" > /dev/null; then
      echo "🗑️  Deleted ${branch} (${reason})"
      ((deleted++))
    else
      echo "⚠️  Failed to delete ${branch}"
      ((failed++))
    fi
  done

  echo "🧹 Stale branch cleanup: deleted=${deleted} skipped=${skipped} failed=${failed}"
  $had_errexit && set -o errexit
}
cleanup_stale_branches || true

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
    -d "{\"body\":\"/payload ${CI_BRANCH} ci blocking\n/payload ${CI_BRANCH} nightly blocking\n/pipeline required\"}" \
    "https://api.github.com/repos/${REPO}/issues/${PR_NUM}/comments"
fi
