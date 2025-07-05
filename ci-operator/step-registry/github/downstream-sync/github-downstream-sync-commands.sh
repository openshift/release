#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# helper to make things more readable below
b64url() {
  openssl base64 -e \
    | tr '/+' '_-' \
    | tr -d '=' \
    | tr -d '\n'
}

ls -altr /secrets
ls -altr /secrets/openshift-ovnk-bot
grep BEGIN $GITHUB_APP_PRIVATE_KEY_FILE
echo $?
grep END $GITHUB_APP_PRIVATE_KEY_FILE
echo $?

# create the JWT needed to get an app install token needed for API requests
NOW=$(date +%s)
EXP=$((NOW + 600))
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":%d}' "$NOW" "$EXP" "$GITHUB_APP_ID" | b64url)
SIG_INPUT="$HEADER.$PAYLOAD"
TMP_KEY=$(mktemp)

TMP_KEY=$(mktemp)

# Wrap the blob with proper PEM headers _and_ force a newline after the blob
{
  echo "-----BEGIN RSA PRIVATE KEY-----"
  cat "$GITHUB_APP_PRIVATE_KEY_FILE"
  echo        # <<< this blank echo guarantees a newline
  echo "-----END RSA PRIVATE KEY-----"
} > "$TMP_KEY"
chmod 600 "$TMP_KEY"

# Quick sanity check (no raw key in logs):
openssl pkey -in "$TMP_KEY" -check -noout

# Now sign against the valid PKCS#1 PEM
SIGNATURE=$(
  printf "%s" "$SIG_INPUT" \
    | openssl dgst -sha256 -sign "$TMP_KEY" \
    | b64url
)

rm -f "$TMP_KEY"



JWT="$HEADER.$PAYLOAD.$SIGNATURE"
INSTALLATION_ID=$(curl -s -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/installation" | jq -r .id)
GITHUB_TOKEN=$(curl -s -H "Authorization: Bearer $JWT" -H "Accept: application/vnd.github+json" -X POST \
    "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" | jq -r .token)

# debug
curl -s -H "Authorization: token $INSTALL_TOKEN" "https://api.github.com/repos/${DOWNSTREAM_REPO}" | jq .
ls -altr ${GITHUB_APP_PRIVATE_KEY}
# end debug


WORKDIR="$(mktemp -d)"
cd "$WORKDIR"

git clone --single-branch --branch "${DEFAULT_BRANCH}" "https://github.com/${DOWNSTREAM_REPO}" repo
cd repo
git remote add upstream "https://github.com/${UPSTREAM_REPO}"
git fetch upstream "${DEFAULT_BRANCH}"
git fetch origin "${DEFAULT_BRANCH}"

# debug: show all the commits
curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls?state=all&base=${DEFAULT_BRANCH}&per_page=100&sort=created&direction=desc"
# end debug

# find last downstream-merge PR
LAST_PR_NUM=$(
  curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls?state=all&base=${DEFAULT_BRANCH}&per_page=100&sort=created&direction=desc" |
    jq -r '.[] | select(.title|test("DownStream Merge \\[[0-9]{2}-[0-9]{2}-[0-9]{4}\\]")) | .number' | head -n1
)
if [[ -n "$LAST_PR_NUM" ]]; then
MERGED=$(
  curl -s -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls/${LAST_PR_NUM}" |
  jq -r .merged
)

# debug, setting MERGED to false so I can see if we can make a PR or not
# MERGED="false"
# [[ "$MERGED" != "true" ]] && { echo "Last PR #${LAST_PR_NUM} not merged; exiting."; exit 0; }
# end debug
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
git remote set-url origin "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${DOWNSTREAM_REPO}"
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
xargs -0 -I{} curl -s -u "${GITHUB_USER}:${GITHUB_TOKEN}" -X POST \
  -d '{}' https://api.github.com/repos/${DOWNSTREAM_REPO}/pulls | jq -r .number
)
if [[ -z "$PR_NUM" || "$PR_NUM" == "null" ]]; then
  echo "ERROR: failed to create PR" >&2
  exit 1
fi
echo "Opened PR #${PR_NUM}."

# hold on conflicts
if [[ "${CONFLICT:-false}" == "true" ]]; then
curl -s -u "${GITHUB_USER}:${GITHUB_TOKEN}" -X POST -d '{"body":"/hold\nneeds conflict resolution"}' \
  "https://api.github.com/repos/${DOWNSTREAM_REPO}/issues/${PR_NUM}/comments"
echo "Conflicts detected; PR #${PR_NUM} held."
exit 1
fi

echo "Merge succeeded; PR #${PR_NUM} created."