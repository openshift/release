#!/bin/bash
set -euo pipefail

# Gangway override: periodic worker receives PR number from trigger presubmit.
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_OAPE_REVIEW_HANDLER_TARGET_PR:-}" ]]; then
  export PULL_NUMBER="${MULTISTAGE_PARAM_OVERRIDE_OAPE_REVIEW_HANDLER_TARGET_PR}"
fi

echo "[setup] Starting oape-review-handler for ${REPO_OWNER}/${REPO_NAME} PR#${PULL_NUMBER:-unknown}"

REHEARSING=false
[[ "${JOB_NAME:-}" == rehearse-* ]] && REHEARSING=true

# pj-rehearse runs against openshift/release, not the target operator repo.
if [[ "${REHEARSING}" == "true" && "${REPO_NAME}" == "release" && "${REPO_OWNER}" == "openshift" && -n "${REHEARSAL_TARGET_REPO:-}" ]]; then
  echo "[setup] Detected openshift/release context — switching to rehearsal target"
  export REPO_OWNER="${REHEARSAL_TARGET_OWNER:-openshift}"
  export REPO_NAME="${REHEARSAL_TARGET_REPO}"
  if [[ -n "${REHEARSAL_TARGET_PR:-}" ]]; then
    export PULL_NUMBER="${REHEARSAL_TARGET_PR}"
  fi
  echo "[setup] Testing against ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER:-unknown}"
fi

if [[ -z "${PULL_NUMBER:-}" ]]; then
  echo "[setup] ERROR: PULL_NUMBER not set. Trigger via Gangway or run as a presubmit." >&2
  exit 1
fi

# GitHub auth: App token with GITHUB_TOKEN fallback
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

# pj-rehearse may set PULL_NUMBER to the release PR; fall back to rehearsal target.
if [[ "${REHEARSING}" == "true" ]] && ! gh pr view "${PULL_NUMBER}" --repo "${REPO_OWNER}/${REPO_NAME}" --json number >/dev/null 2>&1; then
  if [[ -n "${REHEARSAL_TARGET_PR:-}" ]]; then
    echo "[setup] PR #${PULL_NUMBER} not found on ${REPO_OWNER}/${REPO_NAME} — using rehearsal target"
    export PULL_NUMBER="${REHEARSAL_TARGET_PR}"
    echo "[setup] Testing against ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}"
  else
    echo "[setup] ERROR: PR #${PULL_NUMBER} not found on ${REPO_OWNER}/${REPO_NAME}" >&2
    exit 1
  fi
fi

export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-/var/run/claude-code-service-account/google-token}"
export CLAUDE_CODE_USE_VERTEX="1"
export CLOUD_ML_REGION="${CLOUD_ML_REGION:-global}"
export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-openshift-ci-prow-agents}"
export CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"

export PR_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PULL_NUMBER}"
export PLUGINS_DIR="/plugins/oape/skills"

gh auth setup-git
/app/scripts/pr-agent/review-handler.sh --pr-url "$PR_URL"
