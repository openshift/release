#!/bin/bash

GITHUB_AUTH_TOKEN=$(cat /tmp/vault/validatedpatterns-docs-github/GITHUB_AUTH_TOKEN_VP)

export GITHUB_AUTH_TOKEN

PREVIEW_URL="https://${PULL_NUMBER}--patternsdocs-pr.netlify.app"

COMMENT_DATA="🤖 $(date +'%a %b %d %T') - The preview is ready at:\n${PREVIEW_URL}"

# Get the comments
COMMENTS=$(curl -s -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" "https://api.github.com/repos/validatedpatterns/docs/issues/${PULL_NUMBER}/comments")

# Get the list of commenters
PR_COMMENTERS=$(curl -s "https://api.github.com/repos/validatedpatterns/docs/issues/${PULL_NUMBER}/comments" | grep -o '"login":[^,]*' | sed 's/"login": "//' | tr -d '"' | tr -s '\n')

# Check if ocpdocs-previewbot has commented
if echo "$PR_COMMENTERS" | grep -q 'ocpdocs-previewbot'; then
    echo "Updating previous build comment..."
    # Get the ID of ocpdocs-previewbot comment #1
    COMMENT_ID=$(echo "$COMMENTS" | grep -B 3 '"login": "ocpdocs-previewbot"' | grep -o '"id": [0-9]\+' | grep -o '[0-9]\+' | head -n 1)
    # Update comment #1
    curl -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" -X PATCH -d "{\"body\": \"${COMMENT_DATA}\"}" "https://api.github.com/repos/validatedpatterns/docs/issues/comments/${COMMENT_ID}" > /dev/null 2>&1
else
    echo "New PR, adding a new comment ..."
    # Add a new comment
    curl -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" -X POST -d "{\"body\": \"${COMMENT_DATA}\"}" "https://api.github.com/repos/validatedpatterns/docs/issues/${PULL_NUMBER}/comments" > /dev/null 2>&1
fi
