#!/bin/bash
set -euo pipefail

echo "=== Installer Review Agent Trigger ==="

PR_NUMBER="${PULL_NUMBER:-}"
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PULL_NUMBER not set. This step must run as a presubmit."
  exit 1
fi
echo "Triggering review agent for PR #$PR_NUMBER"

UPSTREAM_REPO="${REVIEW_AGENT_UPSTREAM_REPO:-openshift/installer}"
CREDS_DIR="/var/run/claude-code-service-account"
TOKEN_FILE="${CREDS_DIR}/gangway-token"
PAT_FILE="${CREDS_DIR}/${REVIEW_AGENT_PAT_KEY:-gh-pat}"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "ERROR: Gangway token not found at ${TOKEN_FILE}"
  exit 1
fi

POST_DATA=$(jq -n --arg pr "$PR_NUMBER" \
  '{job_execution_type: "1", pod_spec_options: {envs: {MULTISTAGE_PARAM_OVERRIDE_REVIEW_AGENT_TARGET_PR: $pr}}}')

echo "Triggering periodic job: ${PERIODIC_JOB_NAME}"

MAX_RETRIES=10
RETRY_INTERVAL=10
JOB_ID=""

for ((i=1; i<=MAX_RETRIES; i++)); do
  set +x
  RESPONSE=$(curl -s -X POST -d "${POST_DATA}" \
    -H "Authorization: Bearer $(cat "${TOKEN_FILE}")" \
    "${GANGWAY_API}/v1/executions/${PERIODIC_JOB_NAME}" \
    -w "\n%{http_code}")
  set -x
  HTTP_STATUS=$(echo "$RESPONSE" | tail -1)
  JSON_BODY=$(echo "$RESPONSE" | sed '$d')

  if [ "$HTTP_STATUS" -eq 200 ]; then
    JOB_ID=$(echo "$JSON_BODY" | jq -r '.id')
    echo "Job triggered successfully. Job ID: ${JOB_ID}"
    break
  else
    echo "[$i/$MAX_RETRIES] Gangway API returned HTTP $HTTP_STATUS. Retrying in ${RETRY_INTERVAL}s..."
    sleep "$RETRY_INTERVAL"
  fi
done

if [ -z "$JOB_ID" ] || [ "$JOB_ID" = "null" ]; then
  echo "ERROR: Failed to trigger periodic job after $MAX_RETRIES retries"
  exit 1
fi

# Poll gangway for the Prow job URL (up to ~60s)
sleep 10

set +x
JOB_URL=""
for ((i=1; i<=10; i++)); do
  STATUS_RESPONSE=$(curl -s -X GET \
    -H "Authorization: Bearer $(cat "${TOKEN_FILE}")" \
    "${GANGWAY_API}/v1/executions/${JOB_ID}" \
    -w "\n%{http_code}")
  STATUS_HTTP=$(echo "$STATUS_RESPONSE" | tail -1)
  STATUS_BODY=$(echo "$STATUS_RESPONSE" | sed '$d')

  if [ "$STATUS_HTTP" -eq 200 ]; then
    JOB_URL=$(echo "$STATUS_BODY" | jq -r '.job_url // empty')
    if [ -n "$JOB_URL" ]; then
      echo "Job URL: ${JOB_URL}"
      break
    fi
  fi
  echo "[$i/10] Waiting for Prow job URL..."
  sleep 5
done
set -x

# Post a comment on the PR using the PAT
if [ -f "$PAT_FILE" ]; then
  echo "Posting PR comment..."
  [[ $- == *x* ]] && _was_tracing=true || _was_tracing=false
  set +x

  GITHUB_TOKEN_PAT=$(cat "$PAT_FILE")

  if [ -n "$JOB_URL" ]; then
    COMMENT_BODY="Review agent triggered. [View job](${JOB_URL})"
  else
    COMMENT_BODY="Review agent triggered (Gangway execution ID: \`${JOB_ID}\`). The Prow job has not started yet — check the [job history](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/${PERIODIC_JOB_NAME}) for the run once it begins."
  fi

  curl --fail --silent --show-error -X POST \
    -H "Authorization: token ${GITHUB_TOKEN_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${UPSTREAM_REPO}/issues/${PR_NUMBER}/comments" \
    -d "$(jq -n --arg body "$COMMENT_BODY" '{body: $body}')" > /dev/null

  $_was_tracing && set -x || true
  echo "Comment posted on PR #$PR_NUMBER"
else
  echo "WARNING: PAT not found at ${PAT_FILE}, skipping PR comment"
fi

echo "=== Trigger Complete ==="
echo "Job ID: ${JOB_ID}"
echo "Job URL: ${JOB_URL:-pending}"
