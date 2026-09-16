#!/bin/bash
set -euo pipefail

echo "[setup] Starting oape-ci-monitor for ${REPO_OWNER}/${REPO_NAME} PR#${PULL_NUMBER}"

# --- Rehearsal redirect (openshift/release context) ---
if [[ "${REPO_NAME}" == "release" && "${REPO_OWNER}" == "openshift" ]]; then
  if [[ -z "${OAPE_TARGET_REPO:-}" ]]; then
    echo "[setup] ERROR: OAPE_TARGET_REPO not set for openshift/release rehearsal" >&2
    exit 1
  fi
  echo "[setup] Detected openshift/release context — switching to test target ${OAPE_TARGET_REPO}"
  export REPO_OWNER="${OAPE_TARGET_REPO%%/*}"
  export REPO_NAME="${OAPE_TARGET_REPO#*/}"
  export REHEARSAL_MODE="true"
fi

# --- Pin to explicit test PR during staged rollout ---
if [[ -n "${OAPE_TEST_PR_NUMBER:-}" ]]; then
  export PULL_NUMBER="$OAPE_TEST_PR_NUMBER"
  echo "[setup] Testing against pinned PR ${REPO_OWNER}/${REPO_NAME}#${PULL_NUMBER}"
fi

if [[ -z "${PULL_NUMBER:-}" ]]; then
  echo "[setup] ERROR: PULL_NUMBER not set" >&2
  exit 1
fi

# --- GitHub auth: App token with GITHUB_TOKEN fallback ---
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

  INSTALL_HTTP_CODE="000"
  INSTALL_BODY=""
  if INSTALL_RESPONSE=$(curl -fsS --connect-timeout 30 --max-time 60 -w "\n%{http_code}" \
      -H "Authorization: Bearer ${JWT}" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/installation" 2>/dev/null); then
    INSTALL_HTTP_CODE=$(echo "$INSTALL_RESPONSE" | tail -1)
    INSTALL_BODY=$(echo "$INSTALL_RESPONSE" | sed '$d')
  else
    echo "[auth] WARN: GitHub App installation lookup failed, falling back to GITHUB_TOKEN"
  fi

  if [[ "$INSTALL_HTTP_CODE" -eq 200 ]]; then
    INST_ID=$(echo "$INSTALL_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
    TOKEN_HTTP_CODE="000"
    TOKEN_BODY=""
    if TOKEN_RESPONSE=$(curl -fsS --connect-timeout 30 --max-time 60 -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${JWT}" -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${INST_ID}/access_tokens" 2>/dev/null); then
      TOKEN_HTTP_CODE=$(echo "$TOKEN_RESPONSE" | tail -1)
      TOKEN_BODY=$(echo "$TOKEN_RESPONSE" | sed '$d')
    else
      echo "[auth] WARN: GitHub App token creation request failed, falling back to GITHUB_TOKEN"
    fi
    if [[ "$TOKEN_HTTP_CODE" -eq 201 ]]; then
      GH_TOKEN=$(echo "$TOKEN_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
      export GH_TOKEN
      USE_APP_TOKEN="true"
      echo "[auth] GitHub App token generated successfully"
    else
      echo "[auth] WARN: App token creation failed (HTTP ${TOKEN_HTTP_CODE}), falling back to GITHUB_TOKEN"
    fi
  elif [[ "$INSTALL_HTTP_CODE" != "000" ]]; then
    echo "[auth] WARN: App not installed on ${REPO_OWNER}/${REPO_NAME} (HTTP ${INSTALL_HTTP_CODE}), falling back to GITHUB_TOKEN"
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
  echo "[auth] Using GITHUB_TOKEN"
fi
$WAS_TRACING && set -x

gh auth setup-git

# --- Rehearsal: auto-resolve latest open PR when not pinned ---
if [[ "${REHEARSAL_MODE:-}" == "true" && -z "${OAPE_TEST_PR_NUMBER:-}" ]]; then
  PULL_NUMBER=$(gh pr list --repo "${REPO_OWNER}/${REPO_NAME}" \
    --state open --limit 1 --json number --jq '.[0].number')
  if [[ -z "${PULL_NUMBER}" || "${PULL_NUMBER}" == "null" ]]; then
    echo "[setup] ERROR: No open PRs on ${REPO_OWNER}/${REPO_NAME}" >&2
    exit 1
  fi
  export PULL_NUMBER
  echo "[setup] Rehearsal: using latest open PR #${PULL_NUMBER}"
fi

if ! gh pr view "${PULL_NUMBER}" --repo "${REPO_OWNER}/${REPO_NAME}" --json number >/dev/null 2>&1; then
  echo "[setup] ERROR: PR #${PULL_NUMBER} not found on ${REPO_OWNER}/${REPO_NAME}" >&2
  exit 1
fi

export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-/var/run/claude-code-service-account/google-token}"
export CLAUDE_CODE_USE_VERTEX="1"
export CLOUD_ML_REGION="${CLOUD_ML_REGION:-global}"
export ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID:-openshift-ci-prow-agents}"

export DRY_RUN="${DRY_RUN:-true}"
export REVIEW_HANDLER_ENABLED="${REVIEW_HANDLER_ENABLED:-false}"
export PR_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${PULL_NUMBER}"
export SKIP_POLL="${SKIP_POLL:-false}"
export SELF_JOB_NAME="${SELF_JOB_NAME:-oape-ci-monitor}"
export BUILD_ID="${BUILD_ID:-}"
export OAPE_RUN_URL="${BUILD_LOG_URL:-}"
export OAPE_ROOT="${OAPE_ROOT:-/app}"

# Bootstrap until ci-monitor-agent is promoted to quay (built by oape-ai-e2e CI).
if [[ ! -f "${OAPE_ROOT}/scripts/ci-monitor/monitor.sh" ]]; then
  OAPE_AI_E2E_REPO="${OAPE_AI_E2E_REPO:-https://github.com/neha037/oape-ai-e2e.git}"
  OAPE_AI_E2E_COMMIT="${OAPE_AI_E2E_COMMIT:-b4de252c7688f27d243ae73b7fa987ebe2ae8c9c}"
  OAPE_CLONE_DIR=$(mktemp -d)
  echo "[setup] ci-monitor scripts not in image — cloning ${OAPE_AI_E2E_REPO}@${OAPE_AI_E2E_COMMIT:0:7}"
  git clone --depth 1 "${OAPE_AI_E2E_REPO}" "${OAPE_CLONE_DIR}"
  git -C "${OAPE_CLONE_DIR}" checkout "${OAPE_AI_E2E_COMMIT}"
  export OAPE_ROOT="${OAPE_CLONE_DIR}"
fi

"${OAPE_ROOT}/scripts/ci-monitor/monitor.sh"
"${OAPE_ROOT}/scripts/ci-monitor/dispatch.sh"
