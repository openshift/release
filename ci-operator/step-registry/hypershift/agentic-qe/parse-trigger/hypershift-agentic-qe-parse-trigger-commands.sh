#!/bin/bash
set -euo pipefail

PR_NUMBER="${PULL_NUMBER:-}"
if [[ -z "$PR_NUMBER" ]]; then
  echo "PULL_NUMBER not set, skipping trigger comment parsing"
  exit 0
fi

REPO_ORG="${REPO_OWNER:-openshift}"
REPO="${REPO_NAME:-hypershift}"

echo "Parsing trigger comment for PR #${PR_NUMBER} in ${REPO_ORG}/${REPO}"

TRIGGER_COMMENT=$(curl -s "https://api.github.com/repos/${REPO_ORG}/${REPO}/issues/${PR_NUMBER}/comments?per_page=100&direction=desc" \
  | jq -r '[.[] | select(.body | test("/test\\s+agentic-qe"))] | first | .body // empty')

if [[ -z "$TRIGGER_COMMENT" ]]; then
  echo "No trigger comment found, using defaults"
  exit 0
fi

echo "Found trigger comment"

RELEASE_IMAGE=$(echo "$TRIGGER_COMMENT" | grep -oP 'RELEASE_IMAGE=\S+' | head -1 | cut -d= -f2- || true)
if [[ -n "$RELEASE_IMAGE" ]]; then
  echo "Release image override: ${RELEASE_IMAGE}"
  echo "${RELEASE_IMAGE}" > "${SHARED_DIR}/release_image_override"
else
  echo "No RELEASE_IMAGE parameter found, using default"
fi
