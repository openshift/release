#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder Eval Respond ==="

# --- Read tokens and metadata ---
set +x
GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
export GH_FORK_TOKEN
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN

# prow-agent-eval writes metadata with a case-name prefix.
# Read the first case and resolve prefixed filenames.
CASE_NAME=$(head -1 "${SHARED_DIR}/eval-cases")
PR_NUM=$(cat "${SHARED_DIR}/${CASE_NAME}.pr-number")
EVAL_BRANCH=$(cat "${SHARED_DIR}/${CASE_NAME}.eval-head-branch")
JIRA_ISSUE_KEY=$(cat "${SHARED_DIR}/${CASE_NAME}.jira-issue-key")

git config --global credential.helper '!f() { echo username=x-access-token; echo "password=${GH_FORK_TOKEN}"; }; f'

echo "PR: #${PR_NUM} | Branch: ${EVAL_BRANCH} | JIRA: ${JIRA_ISSUE_KEY}"

# --- Clone and checkout ---
WORKDIR="/workspace"
git clone "https://github.com/${UPSTREAM_REPO}.git" "${WORKDIR}"
cd "${WORKDIR}"
git config user.name "openshift-trt"
git config user.email "openshift-trt@redhat.com"
git remote add fork "https://github.com/${FORK_REPO}.git" 2>/dev/null || true
git fetch origin "${EVAL_BRANCH}"
git checkout "${EVAL_BRANCH}"

# --- Setup ---
echo "Running setup script: ${SETUP_SCRIPT}..."
# shellcheck source=/dev/null
source "${WORKDIR}/${SETUP_SCRIPT}"

echo "Installing Claude Code..."
curl -fsSL --retry 3 --retry-delay 5 https://claude.ai/install.sh | sh
export PATH="${HOME}/.local/bin:${PATH}"

# --- Artifact collection ---
mkdir -p "${WORKDIR}/artifacts"
copy_artifacts() {
    echo "Copying artifacts..."
    cp "${WORKDIR}/artifacts/"* "${ARTIFACT_DIR}/" 2>/dev/null || true
    podman logs sippy-postgres > "${ARTIFACT_DIR}/postgres.log" 2>&1 || true
    if [[ -d "${HOME}/.claude/projects" ]]; then
        tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" \
            -C "${HOME}/.claude" projects/ 2>/dev/null || true
    fi
}
trap copy_artifacts EXIT TERM INT

# --- Build SHARED_DIR for review-responder ---
# The production script reads these standard (unprefixed) filenames.
echo "${PR_NUM}" > "${SHARED_DIR}/pr-number"
echo "${JIRA_ISSUE_KEY}" > "${SHARED_DIR}/jira-issue-key"
cp "${SHARED_DIR}/${CASE_NAME}.comment-map.json" "${SHARED_DIR}/comment-map.json"

BOT_LOGIN=$(cat "${SHARED_DIR}/gh-app-bot-login" 2>/dev/null || echo "")
if [[ -z "${BOT_LOGIN}" ]]; then
    echo "ERROR: gh-app-bot-login not found — github-app-auth step must run first"
    exit 1
fi

# --- Run review-responder in eval mode ---
export EVAL_MODE=true
export WORKDIR
/opt/scripts/review-respond.sh

# Convert OTEL with extract_metrics + jq into harness run_result.json.
# Temp autodl stays out of ARTIFACT_DIR so nothing is pushed to BigQuery.
OTEL_LOG="${SHARED_DIR}/claude-otel.jsonl"
if [[ -s "${OTEL_LOG}" ]]; then
    cp "${OTEL_LOG}" "${ARTIFACT_DIR}/claude-otel.jsonl"
    METRICS_TMP=$(mktemp)
    python3 /opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py \
        "${OTEL_LOG}" "${METRICS_TMP}" || true
    if jq -e '.rows[0].model' "${METRICS_TMP}" >/dev/null 2>&1; then
        jq '
          .rows[0] as $r
          | ($r.total_cost_usd | tonumber) as $cost
          | {
              model: $r.model,
              agent: "claude-code",
              agent_version: $r.claude_code_version,
              duration_s: (($r.duration_ms | tonumber) / 1000),
              cost_usd: $cost,
              num_turns: ($r.num_turns | tonumber),
              exit_code: ($r.is_error | tonumber),
              token_usage: {
                input: ($r.input_tokens | tonumber),
                output: ($r.output_tokens | tonumber),
                cache_read: ($r.cache_read_input_tokens | tonumber),
                cache_create: ($r.cache_creation_input_tokens | tonumber)
              },
              per_model_usage: {
                ($r.model): {
                  input: ($r.input_tokens | tonumber),
                  output: ($r.output_tokens | tonumber),
                  cache_read: ($r.cache_read_input_tokens | tonumber),
                  cache_create: ($r.cache_creation_input_tokens | tonumber),
                  cost_usd: $cost
                }
              }
            }
        ' "${METRICS_TMP}" > "${SHARED_DIR}/eval-solve-run-result.json"
        cp "${SHARED_DIR}/eval-solve-run-result.json" "${ARTIFACT_DIR}/eval-solve-run-result.json"
    else
        echo "WARNING: extract_metrics produced no usable row; Run Configuration will be omitted"
    fi
    rm -f "${METRICS_TMP}"
else
    echo "WARNING: no OTEL JSONL collected; Run Configuration will be omitted"
fi

echo "=== TRT Review Responder Eval Respond Complete ==="
