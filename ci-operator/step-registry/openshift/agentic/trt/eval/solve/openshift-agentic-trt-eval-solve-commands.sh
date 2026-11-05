#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Solve ==="

[[ -f "${SHARED_DIR}/github-app-auth.sh" ]] || {
    echo "ERROR: ${SHARED_DIR}/github-app-auth.sh not found — github-app-auth step must run first"
    exit 1
}
# shellcheck source=/dev/null
source "${SHARED_DIR}/github-app-auth.sh"
load_github_tokens
configure_github_git_credentials

# --- Read case list ---
mapfile -t CASE_LIST < "${SHARED_DIR}/eval-cases"
MAX_PARALLEL="${EVAL_PARALLELISM:-5}"
echo "Cases (${#CASE_LIST[@]}): ${CASE_LIST[*]} | Parallelism: ${MAX_PARALLEL}"

# --- Clone repo template ---
TEMPLATE_DIR="/tmp/eval-repo-template"
git clone "https://github.com/${UPSTREAM_REPO}.git" "${TEMPLATE_DIR}"
git -C "${TEMPLATE_DIR}" config user.name "openshift-trt"
git -C "${TEMPLATE_DIR}" config user.email "openshift-trt@redhat.com"
git -C "${TEMPLATE_DIR}" remote add fork "https://github.com/${FORK_REPO}.git"

# --- Shared setup (once) ---
echo "Running setup script: ${SETUP_SCRIPT}..."
cd "${TEMPLATE_DIR}"
# shellcheck source=/dev/null
source "${TEMPLATE_DIR}/${SETUP_SCRIPT}"

echo "Installing Claude Code..."
curl -fsSL --retry 3 --retry-delay 5 https://claude.ai/install.sh | sh
export PATH="${HOME}/.local/bin:${PATH}"

# --- Artifact collection ---
REAL_SHARED_DIR="${SHARED_DIR}"
PR_METADATA_ROOT=$(mktemp -d "/tmp/eval-pr-metadata.XXXXXX")
copy_artifacts() {
    echo "Copying artifacts..."
    for case_name in "${CASE_LIST[@]}"; do
        mkdir -p "${ARTIFACT_DIR}/${case_name}"
        if [[ -d "/workspace/${case_name}/artifacts" ]]; then
            for artifact in "/workspace/${case_name}/artifacts/"*; do
                if [[ "${artifact}" == "/workspace/${case_name}/artifacts/pr-description.md" ]]; then
                    continue
                fi
                cp "${artifact}" "${ARTIFACT_DIR}/${case_name}/" 2>/dev/null || true
            done
        fi
        if [[ -f "${PR_METADATA_ROOT}/${case_name}/pr-description.md" ]]; then
            cp "${PR_METADATA_ROOT}/${case_name}/pr-description.md" \
                "${ARTIFACT_DIR}/${case_name}/pr-description.md" 2>/dev/null || true
        fi
        if [[ -f "/tmp/eval-otel/${case_name}.claude-otel.jsonl" ]]; then
            cp "/tmp/eval-otel/${case_name}.claude-otel.jsonl" "${ARTIFACT_DIR}/${case_name}/claude-otel.jsonl"
        fi
    done
    podman logs sippy-postgres > "${ARTIFACT_DIR}/postgres.log" 2>&1 || true
    if [[ -d "${HOME}/.claude/projects" ]]; then
        tar -czf "${ARTIFACT_DIR}/claude-sessions-$(date +%Y%m%d-%H%M%S).tar.gz" \
            -C "${HOME}/.claude" projects/ 2>/dev/null || true
    fi
}
trap copy_artifacts EXIT TERM INT

# --- Per-case dispatch ---
# Each subshell gets a temp SHARED_DIR with standard filenames the solver expects:
#   reads:  gh-fork-token, gh-upstream-token, jira-issue-key, jira-issue.json, eval-base-branch, eval-case
#   writes: claude-branch, pr-number, pr-description.md, claude-otel.jsonl
RESULTS_DIR="/tmp/eval-results"
OTEL_DIR="/tmp/eval-otel"
mkdir -p "${RESULTS_DIR}" "${OTEL_DIR}"
RUNNING=0

for case_name in "${CASE_LIST[@]}"; do
    CASE_WORKDIR="/workspace/${case_name}"
    BASE_BRANCH=$(cat "${REAL_SHARED_DIR}/${case_name}.eval-base-branch")

    (
        # Build a per-case SHARED_DIR with standard filenames
        CASE_SHARED=$(mktemp -d)
        for f in jira-issue-key jira-issue.json eval-base-branch eval-expected-branch eval-case; do
            cp "${REAL_SHARED_DIR}/${case_name}.${f}" "${CASE_SHARED}/${f}"
        done
        cp "${REAL_SHARED_DIR}/gh-fork-token" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/gh-upstream-token" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/trt-init-model.sh" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/trt-telemetry.sh" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/github-app-auth.sh" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/github-app-token-outputs" "${CASE_SHARED}/"

        cp -r "${TEMPLATE_DIR}" "${CASE_WORKDIR}"
        cd "${CASE_WORKDIR}"
        git fetch origin "${BASE_BRANCH}"
        git checkout "${BASE_BRANCH}"

        export SHARED_DIR="${CASE_SHARED}"
        export WORKDIR="${CASE_WORKDIR}"
        export PR_METADATA_DIR="${PR_METADATA_ROOT}/${case_name}"
        export EVAL_MODE=true
        /opt/scripts/solve.sh

        # Copy small outputs to SHARED_DIR for judge/cleanup. OTEL stays on
        # local disk / artifacts — SHARED_DIR is a 3MiB kube secret.
        for f in claude-branch pr-number pr-description.md; do
            if [[ -f "${CASE_SHARED}/${f}" ]]; then
                cp "${CASE_SHARED}/${f}" "${REAL_SHARED_DIR}/${case_name}.${f}"
            fi
        done
        if [[ -f "${CASE_SHARED}/claude-otel.jsonl" ]]; then
            cp "${CASE_SHARED}/claude-otel.jsonl" "${OTEL_DIR}/${case_name}.claude-otel.jsonl"
        fi

        echo "pass" > "${RESULTS_DIR}/${case_name}"
    ) > "${ARTIFACT_DIR}/solve-${case_name}.log" 2>&1 &

    RUNNING=$(( RUNNING + 1 ))
    if [[ ${RUNNING} -ge ${MAX_PARALLEL} ]]; then
        wait -n || true
        RUNNING=$(( RUNNING - 1 ))
    fi
done

wait || true

# --- Report results ---
echo ""
echo "--- Solve Results ---"
FAILURES=0
for case_name in "${CASE_LIST[@]}"; do
    result=$(cat "${RESULTS_DIR}/${case_name}" 2>/dev/null || echo "fail")
    if [[ "${result}" == "pass" ]]; then
        echo "  [PASS] ${case_name}"
    else
        echo "  [FAIL] ${case_name} (see ${ARTIFACT_DIR}/solve-${case_name}.log)"
        FAILURES=$(( FAILURES + 1 ))
    fi
done

echo "Completed: ${#CASE_LIST[@]} cases, ${FAILURES} failures."

# Combine per-case OTEL on local disk and reshape with extract_metrics + jq
# into eval-solve-run-result.json for prow-agent-eval. Do not put JSONL in
# SHARED_DIR (ci-operator persists it as a 3MiB secret).
OTEL_COMBINED="${OTEL_DIR}/claude-otel.jsonl"
: > "${OTEL_COMBINED}"
for case_name in "${CASE_LIST[@]}"; do
    if [[ -f "${OTEL_DIR}/${case_name}.claude-otel.jsonl" ]]; then
        cat "${OTEL_DIR}/${case_name}.claude-otel.jsonl" >> "${OTEL_COMBINED}"
    fi
done
if [[ -s "${OTEL_COMBINED}" ]]; then
    cp "${OTEL_COMBINED}" "${ARTIFACT_DIR}/claude-otel.jsonl"
    METRICS_TMP=$(mktemp)
    python3 /opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py \
        "${OTEL_COMBINED}" "${METRICS_TMP}" || true
    if ! CODEX_USAGE=$(
        # shellcheck disable=SC1091
        source "${REAL_SHARED_DIR}/trt-telemetry.sh"
        codex_otel_usage "${OTEL_COMBINED}"
    ); then
        CODEX_USAGE=""
    fi
    if [[ -z "${CODEX_USAGE}" ]]; then
        CODEX_USAGE='{"models":{}}'
    fi
    if jq -e '.rows[0]' "${METRICS_TMP}" >/dev/null 2>&1; then
        jq --arg configured "${MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL:-${AGENT_MODEL:-}}" \
           --argjson usage "${CODEX_USAGE}" '
          def first_nonempty: map(select(type == "string" and length > 0)) | first // "";
          .rows[0] as $r
          | ($usage.models // {}) as $models
          | (if $usage.cost_from_metric then ([$models[] | .cost // 0] | add // 0) else ($r.total_cost_usd | tonumber) end) as $cost
          | (if ($models | has($configured)) then $configured
             elif ($r.model | length) > 0 then $r.model
             elif ($models | length) > 0 then ($models | to_entries | max_by(.value.input + .value.cache_read) | .key)
             else $configured end) as $model
          | (if ($model | startswith("gpt-")) then "codex" else "claude-code" end) as $harness
          | (if $harness == "codex" then ([$usage.version, $r.codex_version, $r.claude_code_version] | first_nonempty) else ([$r.claude_code_version] | first_nonempty) end) as $version
          | (if ($models | has($model)) then $models[$model].turns else ($r.num_turns | tonumber) end) as $turns
          | (if ($models | has($model)) then $models[$model].input else ($r.input_tokens | tonumber) end) as $input
          | (if ($models | has($model)) then $models[$model].output else ($r.output_tokens | tonumber) end) as $output
          | (if ($models | has($model)) then $models[$model].cache_read else ($r.cache_read_input_tokens | tonumber) end) as $cache_read
          | (if ($models | has($model)) then $models[$model].cache_create else ($r.cache_creation_input_tokens | tonumber) end) as $cache_create
          | (if ($models | length) > 0 then
              ($models | to_entries | map({
                key: .key,
                value: {
                  input: .value.input,
                  output: .value.output,
                  cache_read: .value.cache_read,
                  cache_create: .value.cache_create,
                  cost_usd: (if $usage.cost_from_metric then (.value.cost // 0) elif .key == $model then $cost else 0 end)
                }
              }) | from_entries)
            else
              {($model): {
                input: ($r.input_tokens | tonumber),
                output: ($r.output_tokens | tonumber),
                cache_read: ($r.cache_read_input_tokens | tonumber),
                cache_create: ($r.cache_creation_input_tokens | tonumber),
                cost_usd: $cost
              }}
            end) as $per_model
          | {
              model: $model,
              agent: $harness,
              agent_version: $version,
              duration_s: (($r.duration_ms | tonumber) / 1000),
              cost_usd: $cost,
              num_turns: $turns,
              exit_code: ($r.is_error | tonumber),
              token_usage: {
                input: $input,
                output: $output,
                cache_read: $cache_read,
                cache_create: $cache_create
              },
              per_model_usage: $per_model
            }
        ' "${METRICS_TMP}" > "${REAL_SHARED_DIR}/eval-solve-run-result.json"
        cp "${REAL_SHARED_DIR}/eval-solve-run-result.json" "${ARTIFACT_DIR}/eval-solve-run-result.json"
    else
        echo "WARNING: extract_metrics produced no usable row; Run Configuration will be omitted"
    fi
    rm -f "${METRICS_TMP}"
else
    echo "WARNING: no OTEL JSONL collected from any case; Run Configuration will be omitted"
fi

# Always exit 0 so the judge step runs and produces the eval summary.
# The judge determines pass/fail based on check results.
echo "=== TRT Eval Solve Complete ==="
