#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Review Responder Eval Respond ==="

[[ -f "${SHARED_DIR}/github-app-auth.sh" ]] || {
    echo "ERROR: ${SHARED_DIR}/github-app-auth.sh not found — github-app-auth step must run first"
    exit 1
}
# shellcheck source=/dev/null
source "${SHARED_DIR}/github-app-auth.sh"
load_github_tokens
configure_github_git_credentials

# prow-agent-eval writes metadata with a case-name prefix.
# Read the first case and resolve prefixed filenames.
CASE_NAME=$(head -1 "${SHARED_DIR}/eval-cases")
PR_NUM=$(cat "${SHARED_DIR}/${CASE_NAME}.pr-number")
EVAL_BRANCH=$(cat "${SHARED_DIR}/${CASE_NAME}.eval-head-branch")
JIRA_ISSUE_KEY=$(cat "${SHARED_DIR}/${CASE_NAME}.jira-issue-key")

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
    EMPTY_OTEL_USAGE='{"codex":{"cost_from_metric":false,"models":{}},"claude_cost":{"present":false,"observed":false,"complete":false}}'
    OTEL_USAGE="${EMPTY_OTEL_USAGE}"
    python3 /opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py \
        "${OTEL_LOG}" "${METRICS_TMP}" || true
    if ! OTEL_USAGE=$(
        # shellcheck disable=SC1091
        source "${SHARED_DIR}/trt-telemetry.sh"
        usage_status=0
        otel_usage "${OTEL_LOG}" || usage_status=$?
        rm -f "${SESSION_PROMPT_FILE}" \
            || echo "WARNING: failed to remove metrics prompt temporary file" >&2
        exit "${usage_status}"
    ); then
        OTEL_USAGE="${EMPTY_OTEL_USAGE}"
    fi
    if ! jq -e 'type == "object" and (.rows | type == "array")' \
        "${METRICS_TMP}" >/dev/null 2>&1; then
        printf '{"rows":[]}\n' > "${METRICS_TMP}"
    fi
    if ! jq -e '
        type == "object"
        and ((.codex.models // {}) | type == "object")
        and ((.claude_cost // {}) | type == "object")
    ' <<< "${OTEL_USAGE}" >/dev/null 2>&1; then
        OTEL_USAGE="${EMPTY_OTEL_USAGE}"
    fi
    if jq -e '(.rows[0] | type == "object")' "${METRICS_TMP}" >/dev/null 2>&1 \
        || jq -e '(.codex.models // {} | length) > 0' <<< "${OTEL_USAGE}" >/dev/null 2>&1; then
        jq --arg configured "${MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL:-${AGENT_MODEL:-}}" \
           --argjson otel_usage "${OTEL_USAGE}" '
          def number_or_zero: try tonumber catch 0;
          def first_nonempty: map(select(type == "string" and length > 0)) | first // "";
          ((.rows[0] | type) == "object") as $has_row
          | (if $has_row then .rows[0] else {} end) as $r
          | $otel_usage.codex as $codex
          | $otel_usage.claude_cost as $claude_cost_status
          | ($codex.models // {}) as $models
          | (($models | length) > 0) as $codex_present
          | ($claude_cost_status.present == true) as $claude_present
          | ($codex.cost_from_metric == true) as $codex_cost_observed
          | (($codex.cost_from_metric == true)
             and ([$models[] | has("cost")] | all)) as $codex_cost_complete
          | ($codex_cost_observed or ($claude_cost_status.observed == true)) as $cost_any_observed
          | ($cost_any_observed
             and (($codex_present | not) or $codex_cost_complete)
             and (($claude_present | not) or ($claude_cost_status.complete == true))) as $cost_observed
          | (if ($r.model | type == "string" and length > 0) then $r.model
             elif ($models | has($configured)) then $configured
             elif ($models | length) > 0 then
               ($models | to_entries | max_by((.value.input // 0) + (.value.cache_read // 0)) | .key)
             elif ($configured | length) > 0 then $configured
             else "unknown" end) as $model
          | (if ($model | startswith("gpt-")) then "codex" else "claude-code" end) as $harness
          | (if $harness == "codex"
             then ([$codex.version, $r.codex_version, $r.claude_code_version] | first_nonempty)
             else ([$r.claude_code_version] | first_nonempty) end) as $version
          | (if $has_row
             then ($r.num_turns | number_or_zero)
             else ([$models[] | .turns // 0] | add // 0) end) as $turns
          | (if $has_row
             then {
               input: ($r.input_tokens | number_or_zero),
               output: ($r.output_tokens | number_or_zero),
               cache_read: ($r.cache_read_input_tokens | number_or_zero),
               cache_create: ($r.cache_creation_input_tokens | number_or_zero)
             }
             else {
               input: ([$models[] | .input // 0] | add // 0),
               output: ([$models[] | .output // 0] | add // 0),
               cache_read: ([$models[] | .cache_read // 0] | add // 0),
               cache_create: ([$models[] | .cache_create // 0] | add // 0)
             } end) as $tokens
          | (if $cost_any_observed
             then (((if $has_row
                      then ($r.total_cost_usd | number_or_zero)
                      else ([$models[] | .cost // 0] | add // 0) end) * 1000000
                    | round) / 1000000)
             else 0 end) as $observed_cost
          | (if $cost_observed then $observed_cost else null end) as $cost
          | (if $codex_present then
              ($models | to_entries | map(
                .value as $usage
                | {
                    key: .key,
                    value: {
                      input: ($usage.input // 0),
                      output: ($usage.output // 0),
                      cache_read: ($usage.cache_read // 0),
                      cache_create: ($usage.cache_create // 0),
                      cost_observed: ($usage | has("cost")),
                      cost_usd: (if ($usage | has("cost")) then $usage.cost else null end),
                      observed_cost_usd: ($usage.cost // 0)
                    }
                  }
              ) | from_entries)
            else
              {($model): ($tokens + {
                cost_observed: $cost_observed,
                cost_usd: $cost,
                observed_cost_usd: $observed_cost
              })}
            end) as $per_model
          | {
              model: $model,
              agent: $harness,
              agent_version: $version,
              duration_s: (if $has_row then (($r.duration_ms | number_or_zero) / 1000) else null end),
              cost_observed: $cost_observed,
              cost_usd: $cost,
              observed_cost_usd: $observed_cost,
              num_turns: $turns,
              exit_code: (if $has_row then ($r.is_error | number_or_zero) else 0 end),
              token_usage: $tokens,
              per_model_usage: $per_model
            }
        ' "${METRICS_TMP}" > "${SHARED_DIR}/eval-solve-run-result.json"
        cp "${SHARED_DIR}/eval-solve-run-result.json" "${ARTIFACT_DIR}/eval-solve-run-result.json"
    else
        echo "WARNING: no usable metrics row or fallback usage; Run Configuration will be omitted"
    fi
    rm -f "${METRICS_TMP}" "${SHARED_DIR}/claude-otel.jsonl"
else
    echo "WARNING: no OTEL JSONL collected; Run Configuration will be omitted"
fi

echo "=== TRT Review Responder Eval Respond Complete ==="
