#!/bin/bash

# We don't care if the GH comment step fails
# set -o nounset
# set -o errexit
# set -o pipefail

GITHUB_AUTH_TOKEN=$(cat /tmp/vault/ocp-docs-github-secret/GITHUB_AUTH_TOKEN)

export GITHUB_AUTH_TOKEN

PREVIEW_URL="https://${PULL_NUMBER}--${PREVIEW_SITE}.netlify.app"

COMMENT_DATA="🤖 $(date +'%a %b %d %T') - Prow CI generated the docs preview:\n"

# If there are more than 10 preview URLs, write to a file in the CI job artifacts folder instead
if [ -e "${SHARED_DIR}/UPDATED_PAGES" ]; then
    num_lines=$(wc -l < "${SHARED_DIR}/UPDATED_PAGES")
    if [ "$num_lines" -le 10 ]; then
        while IFS= read -r updated_page; do
            COMMENT_DATA+="\n${updated_page}"
        done < "${SHARED_DIR}/UPDATED_PAGES"
    else
        cp "${SHARED_DIR}/UPDATED_PAGES" "${ARTIFACT_DIR}"/updated_preview_urls.txt
        COMMENT_DATA+="${PREVIEW_URL}\n...[URLs list truncated]...\nThe complete list of updated URLs is in the Prow CI job artifacts/deploy-preview/openshift-docs-preview-comment/artifacts/ folder."
    fi
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
