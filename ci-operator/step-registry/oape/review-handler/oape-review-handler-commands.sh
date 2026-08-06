#!/bin/bash
set -euo pipefail

echo "[setup] Starting oape-review-handler for ${REPO_OWNER}/${REPO_NAME} PR#${PULL_NUMBER}"

# --- Rehearsal detection ---
if [[ "${REPO_NAME}" == "release" && "${REPO_OWNER}" == "openshift" ]]; then
  echo "[setup] Detected openshift/release context — switching to test target"
  export REPO_OWNER="openshift"
  export REPO_NAME="must-gather-operator"
  TEST_PR=$(curl -s "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/pulls?state=open&per_page=1" \
    | python3 -c "import sys,json; data=json.load(sys.stdin); print(data[0]['number'] if data else '')" 2>/dev/null || echo "")
  if [[ -z "$TEST_PR" ]]; then
    echo "[setup] No open PRs found — skipping"
    exit 0
  fi
  export PULL_NUMBER="$TEST_PR"
  echo "[setup] Testing against ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}"
fi

# --- GitHub auth: App token with GITHUB_TOKEN fallback ---
USE_APP_TOKEN="false"
if [[ -f /var/run/github-app/app-id && -f /var/run/github-app/private-key.pem ]]; then
  echo "[auth] Attempting GitHub App token..."
  APP_ID=$(cat /var/run/github-app/app-id)
  PEM_PATH="/var/run/github-app/private-key.pem"
  HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  NOW=$(date +%s); EXP=$((NOW + 300))
  PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$NOW" "$EXP" "$APP_ID" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  SIGNATURE=$(printf '%s' "${HEADER}.${PAYLOAD}" | openssl dgst -sha256 -sign "$PEM_PATH" -binary | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  JWT="${HEADER}.${PAYLOAD}.${SIGNATURE}"
  INSTALL_RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer ${JWT}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/installation")
  HTTP_CODE=$(echo "$INSTALL_RESPONSE" | tail -1)
  INSTALL_BODY=$(echo "$INSTALL_RESPONSE" | sed '$d')
  if [[ "$HTTP_CODE" -eq 200 ]]; then
    INST_ID=$(echo "$INSTALL_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    TOKEN_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Authorization: Bearer ${JWT}" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/app/installations/${INST_ID}/access_tokens")
    T_CODE=$(echo "$TOKEN_RESPONSE" | tail -1)
    T_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')
    if [[ "$T_CODE" -eq 201 ]]; then
      export GH_TOKEN=$(echo "$T_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
      USE_APP_TOKEN="true"
      echo "[auth] GitHub App token generated successfully"
    else
      echo "[auth] WARN: App token creation failed (HTTP ${T_CODE}), falling back to GITHUB_TOKEN"
    fi
  else
    echo "[auth] WARN: App not installed on ${REPO_OWNER}/${REPO_NAME} (HTTP ${HTTP_CODE}), falling back to GITHUB_TOKEN"
  fi
else
  echo "[auth] GitHub App credentials not mounted, using GITHUB_TOKEN"
fi
if [[ "$USE_APP_TOKEN" != "true" ]]; then
  if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" ]]; then
    echo "[auth] ERROR: No GitHub token available" >&2
    exit 1
  fi
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN}}"
fi

# --- GCP auth for Claude (Vertex AI) ---
export GOOGLE_APPLICATION_CREDENTIALS="/var/run/gcloud-adc/application_default_credentials.json"
export CLAUDE_CODE_USE_VERTEX="1"
export CLOUD_ML_REGION="global"
export ANTHROPIC_VERTEX_PROJECT_ID="itpc-gcp-hcm-pe-eng-claude"

# --- Run review handler ---
export PR_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PULL_NUMBER}"
export PLUGINS_DIR="/plugins/oape/skills"

gh auth setup-git
/app/scripts/pr-agent/review-handler.sh --pr-url "$PR_URL"
