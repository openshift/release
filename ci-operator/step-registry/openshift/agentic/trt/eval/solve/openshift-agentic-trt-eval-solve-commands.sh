#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Solve ==="

# --- Read tokens ---
set +x
GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
export GH_FORK_TOKEN
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN

git config --global credential.helper '!f() { echo username=x-access-token; echo "password=${GH_FORK_TOKEN}"; }; f'

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
copy_artifacts() {
    echo "Copying artifacts..."
    for case_name in "${CASE_LIST[@]}"; do
        mkdir -p "${ARTIFACT_DIR}/${case_name}"
        if [[ -d "/workspace/${case_name}/artifacts" ]]; then
            cp "/workspace/${case_name}/artifacts/"* "${ARTIFACT_DIR}/${case_name}/" 2>/dev/null || true
        fi
        if [[ -f "${REAL_SHARED_DIR}/${case_name}.claude-otel.jsonl" ]]; then
            cp "${REAL_SHARED_DIR}/${case_name}.claude-otel.jsonl" "${ARTIFACT_DIR}/${case_name}/claude-otel.jsonl"
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
mkdir -p "${RESULTS_DIR}"
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

        cp -r "${TEMPLATE_DIR}" "${CASE_WORKDIR}"
        cd "${CASE_WORKDIR}"
        git fetch origin "${BASE_BRANCH}"
        git checkout "${BASE_BRANCH}"

        export SHARED_DIR="${CASE_SHARED}"
        export WORKDIR="${CASE_WORKDIR}"
        export EVAL_MODE=true
        /opt/scripts/solve.sh

        # Copy outputs back as flat files for judge/cleanup
        for f in claude-branch pr-number pr-description.md claude-otel.jsonl; do
            if [[ -f "${CASE_SHARED}/${f}" ]]; then
                cp "${CASE_SHARED}/${f}" "${REAL_SHARED_DIR}/${case_name}.${f}"
            fi
        done

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

# Combine per-case OTEL and reshape with extract_metrics + jq into the
# harness run_result.json that prow-agent-eval uses for Run Configuration.
# Temp autodl stays out of ARTIFACT_DIR so nothing is pushed to BigQuery.
OTEL_COMBINED="${REAL_SHARED_DIR}/claude-otel.jsonl"
: > "${OTEL_COMBINED}"
for case_name in "${CASE_LIST[@]}"; do
    if [[ -f "${REAL_SHARED_DIR}/${case_name}.claude-otel.jsonl" ]]; then
        cat "${REAL_SHARED_DIR}/${case_name}.claude-otel.jsonl" >> "${OTEL_COMBINED}"
    fi
done
if [[ -s "${OTEL_COMBINED}" ]]; then
    cp "${OTEL_COMBINED}" "${ARTIFACT_DIR}/claude-otel.jsonl"
    METRICS_TMP=$(mktemp)
    python3 /opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py \
        "${OTEL_COMBINED}" "${METRICS_TMP}" || true
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
