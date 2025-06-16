#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x


GITHUB_TOKEN_FILE="$SECRETS_PATH/$GITHUB_SECRET/$GITHUB_SECRET_FILE"
echo "    GITHUB_TOKEN_FILE  = $GITHUB_TOKEN_FILE"
TOKEN=$(cat "$GITHUB_TOKEN_FILE")

WORKDIR="$(mktemp -d)"
cd "$WORKDIR"

git clone --single-branch --branch "${DEFAULT_BRANCH}" "${DOWNSTREAM_REPO}" repo
cd repo
git remote add upstream "${UPSTREAM_REPO}"
git fetch upstream "${DEFAULT_BRANCH}"
git fetch origin "${DEFAULT_BRANCH}"

# find last downstream-merge PR
LAST_PR_NUM=$(
curl -s -H "Authorization: token $TOKEN" \
  "https://api.github.com/repos/openshift/ovn-kubernetes/pulls?state=all&per_page=50&sort=created&direction=desc" |
jq -r '.[]
  | select(.title|test("DownStream Merge [0-9]{2}-[0-9]{2}-[0-9]{4}")) | .number' |
head -n1
)
if [[ -n "$LAST_PR_NUM" ]]; then
MERGED=$(
  curl -s -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/openshift/ovn-kubernetes/pulls/${LAST_PR_NUM}" |
  jq -r .merged
)
[[ "$MERGED" != "true" ]] && { echo "Last PR #${LAST_PR_NUM} not merged; exiting."; exit 0; }
fi

NEW_COMMITS=$(git rev-list origin/${DEFAULT_BRANCH}..upstream/${DEFAULT_BRANCH} --count)
echo "Found $NEW_COMMITS new commits upstream."
(( NEW_COMMITS < MIN_COMMITS )) && { echo "Below threshold; exiting."; exit 0; }

# do the merge
BRANCH="d/s-merge-$(date +%m-%d-%Y)"
git checkout -b "$BRANCH" origin/${DEFAULT_BRANCH}
if ! git merge -X theirs "upstream/${DEFAULT_BRANCH}"; then
git add -A
git commit -m "Merge upstream/${DEFAULT_BRANCH} into ${DEFAULT_BRANCH} with conflicts ($(date +%m-%d-%Y))"
CONFLICT=true
fi
git push origin "$BRANCH"

# open the PR
PR_TITLE="NO-JIRA: DownStream Merge $(date +%m-%d-%Y)"
PR_BODY="Automated merge of upstream/${DEFAULT_BRANCH} → ${DEFAULT_BRANCH}."
PR_NUM=$(
jq -nr \
  --arg t "$PR_TITLE" \
  --arg b "$BRANCH" \
  --arg base "$DEFAULT_BRANCH" \
  --arg body "$PR_BODY" \
  '{title:$t, head:$b, base:$base, body:$body}' |
xargs -0 -I{} curl -s -X POST \
  -H "Authorization: token $TOKEN" -d '{}' \
  https://api.github.com/repos/openshift/ovn-kubernetes/pulls |
jq -r .number
)
echo "Opened PR #${PR_NUM}."

# hold on conflicts
if [[ "${CONFLICT:-false}" == "true" ]]; then
curl -s -X POST -H "Authorization: token $TOKEN" \
  -d '{"body":"/hold\nneeds conflict resolution"}' \
  "https://api.github.com/repos/openshift/ovn-kubernetes/issues/${PR_NUM}/comments"
echo "Conflicts detected; PR #${PR_NUM} held."
exit 1
fi

echo "Merge succeeded; PR #${PR_NUM} created."