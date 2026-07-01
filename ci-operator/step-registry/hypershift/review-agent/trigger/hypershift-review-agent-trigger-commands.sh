#!/bin/bash
set -euo pipefail

echo "=== HyperShift Review Agent Trigger ==="

PR_NUMBER="${PULL_NUMBER:-}"
if [ -z "$PR_NUMBER" ]; then
  echo "ERROR: PULL_NUMBER not set. This step must run as a presubmit."
  exit 1
fi
echo "Triggering review agent for PR #$PR_NUMBER"

CREDS_DIR="/var/run/claude-code-service-account"
TOKEN_FILE="${CREDS_DIR}/gangway-token"
APP_ID_FILE="${CREDS_DIR}/app-id"
INSTALLATION_ID_UPSTREAM_FILE="${CREDS_DIR}/o-h-installation-id"
PRIVATE_KEY_FILE="${CREDS_DIR}/private-key"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "ERROR: Gangway token not found at ${TOKEN_FILE}"
  exit 1
fi

generate_github_token() {
  local INSTALL_ID=$1
  local APP_ID
  APP_ID=$(cat "$APP_ID_FILE")
  local NOW
  NOW=$(date +%s)
  local IAT=$((NOW - 60))
  local EXP=$((NOW + 600))

  local HEADER
  HEADER=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  local PAYLOAD
  PAYLOAD=$(echo -n "{\"iat\":${IAT},\"exp\":${EXP},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  local SIGNATURE
  SIGNATURE=$(echo -n "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
  local JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"

  curl -s -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" \
    | jq -r '.token'
}

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

# Wait briefly for prow to create the job so we can get the URL
sleep 5

set +x
JOB_URL=""
for ((i=1; i<=5; i++)); do
  STATUS_RESPONSE=$(curl -s -X GET \
    -H "Authorization: Bearer $(cat "${TOKEN_FILE}")" \
    "${GANGWAY_API}/v1/executions/${JOB_ID}" \
    -w "\n%{http_code}")
  STATUS_HTTP=$(echo "$STATUS_RESPONSE" | tail -1)
  STATUS_BODY=$(echo "$STATUS_RESPONSE" | sed '$d')

  if [ "$STATUS_HTTP" -eq 200 ]; then
    JOB_URL=$(echo "$STATUS_BODY" | jq -r '.job_url // empty')
    JOB_STATUS=$(echo "$STATUS_BODY" | jq -r '.job_status // "UNKNOWN"')
    if [ -n "$JOB_URL" ]; then
      echo "Job URL: ${JOB_URL}"
      break
    fi
  fi
  sleep 5
done
set -x

# Post a comment on the PR
if [ -f "$APP_ID_FILE" ] && [ -f "$INSTALLATION_ID_UPSTREAM_FILE" ] && [ -f "$PRIVATE_KEY_FILE" ]; then
  echo "Generating GitHub token to post PR comment..."
  INSTALLATION_ID_UPSTREAM=$(cat "$INSTALLATION_ID_UPSTREAM_FILE")
  GITHUB_TOKEN=$(generate_github_token "$INSTALLATION_ID_UPSTREAM")

  if [ -n "$GITHUB_TOKEN" ] && [ "$GITHUB_TOKEN" != "null" ]; then
    PROW_LINK="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${PERIODIC_JOB_NAME}/${JOB_ID}"
    if [ -n "$JOB_URL" ]; then
      PROW_LINK="$JOB_URL"
    fi

    COMMENT_BODY="Review agent triggered. [View job](${PROW_LINK})"

    set +x
    curl -s -X POST \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/openshift/hypershift/issues/${PR_NUMBER}/comments" \
      -d "$(jq -n --arg body "$COMMENT_BODY" '{body: $body}')" > /dev/null
    set -x
    echo "Comment posted on PR #$PR_NUMBER"
  else
    echo "WARNING: Failed to generate GitHub token for PR comment"
  fi
else
  echo "WARNING: GitHub App credentials not available, skipping PR comment"
fi

echo "=== Trigger Complete ==="
echo "Job ID: ${JOB_ID}"
echo "Job URL: ${JOB_URL:-pending}"
