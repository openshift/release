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

# For backward compatibility, use DEFAULT_BRANCH for upstream if UPSTREAM_BRANCH not set
if [[ -z "${UPSTREAM_BRANCH:-}" ]]; then
  UPSTREAM_BRANCH="${DEFAULT_BRANCH}"
  echo "ℹ️  UPSTREAM_BRANCH not set, using DEFAULT_BRANCH (${DEFAULT_BRANCH}) for upstream"
fi

echo "📥 Cloning repo and setting up remotes…"
# get the repo
WORKDIR="$(mktemp -d)"
cd "$WORKDIR"
git clone --single-branch --branch "${DEFAULT_BRANCH}" "https://github.com/${DOWNSTREAM_REPO}" repo
cd repo
git remote add upstream "https://github.com/${UPSTREAM_REPO}"
git fetch upstream "${UPSTREAM_BRANCH}"
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
NEW_COMMITS=$(git rev-list origin/"${DEFAULT_BRANCH}"..upstream/"${UPSTREAM_BRANCH}" --count)
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
if ! git merge "upstream/${UPSTREAM_BRANCH}"; then
  echo "⚠️  Merge conflict detected"

  # Capture list of conflicted files for diagnostics
  CONFLICTED_FILES=$(git diff --name-only --diff-filter=U)
  echo "Conflicted files:"
  echo "$CONFLICTED_FILES"

  git add -A
  CONFLICT_MSG="Merge upstream/${UPSTREAM_BRANCH} into ${DEFAULT_BRANCH} with conflicts ($(date +%m-%d-%Y))

Conflicted files:
$CONFLICTED_FILES"
  git commit -m "$CONFLICT_MSG"
  CONFLICT=true
fi

# Skip go mod tidy and test sync if there are conflicts - they should be run after manual resolution
if [[ "${CONFLICT:-false}" == "true" ]]; then
  echo "⚠️  Skipping go mod tidy and test sync due to merge conflicts"
  echo "   These should be run manually after resolving conflicts"
else
  echo "🔧 Syncing openshift/go.mod with upstream dependencies…"
  pushd openshift > /dev/null
  if go mod tidy; then
    popd > /dev/null
    # Check if there are any changes to commit
    if ! git diff --quiet openshift/go.mod openshift/go.sum; then
      echo "   📝 Changes detected in openshift/go.mod, committing…"
      git add openshift/go.mod openshift/go.sum
      git commit -m "sync openshift/go.mod with upstream dependencies

- go mod tidy

Automated sync after downstream merge to keep openshift/go.mod
in sync with transitive dependencies from go-controller and test/e2e."
      echo "   ✅ openshift/go.mod synced successfully"
      GO_MOD_SYNCED=true
    else
      echo "   ℹ️  No changes needed in openshift/go.mod"
    fi
  else
    popd > /dev/null
    echo "   ⚠️  go mod tidy failed in openshift/"
    GO_MOD_FAILED=true
  fi
fi

if [[ "${GO_MOD_FAILED:-false}" != "true" ]] && [[ "${CONFLICT:-false}" != "true" ]]; then
  echo "🧪 Syncing test annotations with upstream changes…"
  pushd openshift > /dev/null
  if go mod vendor; then
    popd > /dev/null
    if ./openshift/hack/update-tests-annotation.sh; then
      if ! git diff --quiet openshift/test/generated/zz_generated.annotations.go; then
        echo "   📝 Changes detected in test annotations, committing…"
        git add openshift/test/generated/zz_generated.annotations.go
        git commit -m "sync test annotations with upstream changes

- go mod vendor
- ./openshift/hack/update-tests-annotation.sh

Automated sync after downstream merge to keep test annotations
in sync with upstream test modifications and rules.go changes."
        echo "   ✅ Test annotations synced successfully"
        TEST_ANNOTATIONS_SYNCED=true
      else
        echo "   ℹ️  No changes needed in test annotations"
      fi
    else
      echo "   ⚠️  Test annotation sync failed"
      TEST_ANNOTATIONS_FAILED=true
    fi
  else
    popd > /dev/null
    echo "   ⚠️  Test annotation sync failed"
    TEST_ANNOTATIONS_FAILED=true
  fi
fi

echo "📤 Pushing branch to origin…"
git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${DOWNSTREAM_REPO}"
git push origin "$BRANCH"

echo "✏️  Opening Pull Request…"
PR_TITLE="NO-JIRA: DownStream Merge [$(date +%m-%d-%Y)]"
PR_BODY="Automated merge of upstream/${UPSTREAM_BRANCH} → ${DEFAULT_BRANCH}."
if [[ "${GO_MOD_SYNCED:-false}" == "true" ]]; then
  PR_BODY="${PR_BODY}"$'\n\n'"**Note:** This PR includes an automated sync of \`openshift/go.mod\` with upstream dependencies (\`go mod tidy\`)."
fi
if [[ "${TEST_ANNOTATIONS_SYNCED:-false}" == "true" ]]; then
  PR_BODY="${PR_BODY}"$'\n\n'"**Note:** This PR includes an automated sync of test annotations with upstream test changes (\`go mod vendor\` + \`update-tests-annotation.sh\`)."
fi
if [[ "${CONFLICT:-false}" == "true" ]]; then
  PR_BODY="${PR_BODY}"$'\n\n'"**⚠️  Merge Conflicts Detected**"$'\n\n'"The following files have conflicts:"$'\n\n'"<details><summary>Click to expand</summary>"$'\n\n'"<pre>${CONFLICTED_FILES}</pre></details>"
fi
# Make it a draft if we detected conflicts or go mod failures (keeps Prow from auto-running presubmits).
DRAFT=$( [[ "${CONFLICT:-false}" == "true" || "${GO_MOD_FAILED:-false}" == "true" || "${TEST_ANNOTATIONS_FAILED:-false}" == "true" ]] && echo true || echo false )
# Build the PR JSON $PAYLOAD
PAYLOAD=$(
  jq -nc \
    --arg title     "$PR_TITLE" \
    --arg head      "$BRANCH" \
    --arg base      "$DEFAULT_BRANCH" \
    --arg body      "$PR_BODY" \
    --argjson draft "$DRAFT" \
    '{title: $title, head: $head, base: $base, body: $body, draft: $draft}'
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

if [[ "${CONFLICT:-false}" == "true" || "${GO_MOD_FAILED:-false}" == "true" || "${TEST_ANNOTATIONS_FAILED:-false}" == "true" ]]; then
  FAILURES=()
  STEPS=()

  [[ "${CONFLICT:-false}" == "true" ]] && FAILURES+=("CONFLICT") && STEPS+=("Resolve merge conflicts")
  [[ "${GO_MOD_FAILED:-false}" == "true" ]] && FAILURES+=("GO MOD FAILED") && STEPS+=("Run: cd openshift && go mod tidy")
  [[ "${TEST_ANNOTATIONS_FAILED:-false}" == "true" ]] && FAILURES+=("TEST ANNOTATIONS FAILED") && STEPS+=("Run: go mod vendor && ./openshift/hack/update-tests-annotation.sh")

  TITLE_PREFIX=$(IFS=" + "; echo "${FAILURES[*]}")
  HOLD_REASON="/hold"
  for step in "${STEPS[@]}"; do
    HOLD_REASON="${HOLD_REASON}\n${step}"
  done

  echo "🚨 ${TITLE_PREFIX}, holding PR #${PR_NUM}"
  NEW_TITLE="${TITLE_PREFIX}! ${PR_TITLE}"
  TITLE_PAYLOAD=$(jq -nc --arg title "$NEW_TITLE" '{title: $title}')
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X PATCH -d "$TITLE_PAYLOAD" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls/${PR_NUM}"
  COMMENT_PAYLOAD=$(jq -nc --arg body "$HOLD_REASON" '{body: $body}')
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X POST -d "$COMMENT_PAYLOAD" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/issues/${PR_NUM}/comments"
  echo "⚠️  PR #${PR_NUM} held for manual resolution"
  exit 1
else
  echo "💬 Posting /ok-to-test and payload commands…"
  OK_TO_TEST_BODY="/ok-to-test
/payload ${RELEASE} ci blocking
/payload ${RELEASE} nightly blocking"
  OK_TO_TEST_PAYLOAD=$(jq -nc --arg body "$OK_TO_TEST_BODY" '{body: $body}')
  curl -sS -H "Authorization: token ${GITHUB_TOKEN}" -X POST \
       -d "$OK_TO_TEST_PAYLOAD" \
       "https://api.github.com/repos/${DOWNSTREAM_REPO}/issues/${PR_NUM}/comments"
fi

echo "✅ Merge succeeded; PR #${PR_NUM} created."
