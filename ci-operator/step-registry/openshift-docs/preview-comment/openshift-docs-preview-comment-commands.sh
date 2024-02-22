#!/bin/bash

# We don't care if the GH comment step fails
# set -o nounset
# set -o errexit
# set -o pipefail

GITHUB_AUTH_TOKEN=$(cat /tmp/vault/ocp-docs-github-secret/GITHUB_AUTH_TOKEN)

export GITHUB_AUTH_TOKEN

PREVIEW_URL="https://${PULL_NUMBER}--${PREVIEW_SITE}.netlify.app"
pages=("")

if [ -e "${SHARED_DIR}/NETLIFY_SUCCESS" ]; then
    COMMENT_DATA="🤖 $(date +'%a %b %d %T') - Prow CI generated the docs preview: ${PREVIEW_URL}"
elif [ -e "${SHARED_DIR}/UPDATED_PAGES" ]; then
    COMMENT_DATA="🤖 $(date +'%a %b %d %T') - Prow CI generated the docs preview:"

    # Get the list of URLs generated in the build step
    while IFS= read -r updated_page; do
        pages+=("${updated_page}")
    done < "${SHARED_DIR}/UPDATED_PAGES"

    # Append the page URLs to the comment data
    for page in "${pages[@]}"; do
        COMMENT_DATA+="\n${page}"
    done
fi

# Get the comments
COMMENTS=$(curl -s -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" "https://api.github.com/repos/openshift/openshift-docs/issues/${PULL_NUMBER}/comments")

# Get the list of commenters
PR_COMMENTERS=$(curl -s "https://api.github.com/repos/openshift/openshift-docs/issues/${PULL_NUMBER}/comments" | grep -o '"login":[^,]*' | sed 's/"login": "//' | tr -d '"' | tr -s '\n')

# Check if ocpdocs-previewbot has commented
if echo "$PR_COMMENTERS" | grep -q 'ocpdocs-previewbot'; then
    echo "Updating previous build comment..."
    # Get the ID of ocpdocs-previewbot comment #1 
    COMMENT_ID=$(echo "$COMMENTS" | grep -B 3 '"login": "ocpdocs-previewbot"' | grep -o '"id": [0-9]\+' | grep -o '[0-9]\+' | head -n 1)
    # Update comment #1
    curl -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" -X PATCH -d "{\"body\": \"${COMMENT_DATA}\"}" "https://api.github.com/repos/openshift/openshift-docs/issues/comments/${COMMENT_ID}" > /dev/null 2>&1
else
    echo "New PR, adding a new bot comment ..."
    # Add a new comment
    curl -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_AUTH_TOKEN}" -X POST -d "{\"body\": \"${COMMENT_DATA}\"}" "https://api.github.com/repos/openshift/openshift-docs/issues/${PULL_NUMBER}/comments" > /dev/null 2>&1
fi
