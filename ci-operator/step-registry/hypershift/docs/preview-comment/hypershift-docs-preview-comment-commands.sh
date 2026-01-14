#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

PREVIEW_URL=$(cat "${SHARED_DIR}/preview-url")
GITHUB_TOKEN=$(cat /var/run/vault/github-token/oauth)

# Post comment to PR
COMMENT_BODY="## Documentation Preview

Your documentation changes are available for preview at:
**${PREVIEW_URL}**

_Deployed to Cloudflare Pages._"

curl -sf -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/openshift/hypershift/issues/${PULL_NUMBER}/comments" \
    -d "$(jq -n --arg body "${COMMENT_BODY}" '{body: $body}')"

echo "Posted preview comment to PR #${PULL_NUMBER}"
