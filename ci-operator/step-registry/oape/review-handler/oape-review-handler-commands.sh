#!/bin/bash
set -euo pipefail

echo "[setup] Starting oape-review-handler for ${REPO_OWNER}/${REPO_NAME} PR#${PULL_NUMBER}"

# --- Rehearsal redirect (release context) ---
# pj-rehearse runs against openshift/release, not the target repo.
# Redirect before auth so the GitHub App lookup targets the correct repo.
if [[ "${REPO_NAME}" == "release" && "${REPO_OWNER}" == "openshift" ]]; then
  echo "[setup] Detected openshift/release context — switching to test target"
  export REPO_OWNER="openshift"
  export REPO_NAME="must-gather-operator"
  export PULL_NUMBER="${REHEARSAL_TARGET_PR:-385}"
  echo "[setup] Testing against ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}"
fi

# --- GitHub auth: App token with GITHUB_TOKEN fallback ---
# Disable tracing due to JWT / token handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
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
      GH_TOKEN=$(echo "$T_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
      export GH_TOKEN
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
$WAS_TRACING && set -x

# --- Rehearsal redirect (invalid PR on must-gather-operator) ---
# Catches the case where pj-rehearse sets REPO_NAME=must-gather-operator but
# PULL_NUMBER is the release PR number (e.g. 81200, which doesn't exist on MGO).
if [[ "${REPO_OWNER}" == "openshift" && "${REPO_NAME}" == "must-gather-operator" && -n "${PULL_NUMBER:-}" ]]; then
  if ! gh pr view "${PULL_NUMBER}" --repo openshift/must-gather-operator --json number >/dev/null 2>&1; then
    echo "[setup] PR #${PULL_NUMBER} not found on must-gather-operator — using rehearsal target"
    export PULL_NUMBER="${REHEARSAL_TARGET_PR:-385}"
    echo "[setup] Testing against ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}"
  fi
fi

# --- GCP auth for Claude (Vertex AI) ---
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-/var/run/claude-code-service-account/google-token}"
export CLAUDE_CODE_USE_VERTEX="1"
export CLOUD_ML_REGION="${CLOUD_ML_REGION:-global}"
export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-openshift-ci-prow-agents}"
export CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"

# --- Run review handler ---
export PR_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PULL_NUMBER}"
export PLUGINS_DIR="/plugins/oape/skills"

gh auth setup-git
/app/scripts/pr-agent/review-handler.sh --pr-url "$PR_URL"
