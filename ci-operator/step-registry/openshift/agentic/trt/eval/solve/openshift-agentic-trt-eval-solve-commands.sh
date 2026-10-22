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
copy_artifacts() {
    echo "Copying artifacts..."
    for case_name in "${CASE_LIST[@]}"; do
        mkdir -p "${ARTIFACT_DIR}/${case_name}"
        if [[ -d "/workspace/${case_name}/artifacts" ]]; then
            cp "/workspace/${case_name}/artifacts/"* "${ARTIFACT_DIR}/${case_name}/" 2>/dev/null || true
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
OTEL_DIR="/tmp/eval-otel"
mkdir -p "${OTEL_DIR}"
RUNNING=0

for case_name in "${CASE_LIST[@]}"; do
    CASE_WORKDIR="/workspace/${case_name}"
    (
        CASE_SHARED=""
        CASE_PHASE=preparation
        finish_case() {
            local rc=$?
            trap - EXIT
            # Do not lose status, publication metadata, or telemetry when the
            # solver exits nonzero. Keep bulk logs out of the shared secret.
            python3 - "${CASE_SHARED}" "${REAL_SHARED_DIR}" "${case_name}" \
                "${ARTIFACT_DIR}" "${OTEL_DIR}" "${rc}" "${CASE_PHASE}" <<'CASE_STATUS_PY'
import json
from pathlib import Path
import shutil
import sys

case_shared, shared, case, artifacts, otel, code, phase = sys.argv[1:]
shared, artifacts, otel = Path(shared), Path(artifacts), Path(otel)
rc = int(code)
status = {"status": "failed", "phase": phase, "exit_code": rc or 1,
          "reason": f"case exited during {phase}; see solve-{case}.log"}
if case_shared:
    source = Path(case_shared)
    try:
        status = json.loads((source / "solve-status.json").read_text())
        if not isinstance(status, dict) or type(status.get("exit_code")) is not int:
            raise ValueError("invalid solver status")
        if status.get("status") != "passed" or status.get("exit_code") != 0:
            rc = rc or status.get("exit_code") or 1
        elif rc != 0:
            status = {"phase": phase, "reason": f"case failed during {phase} after solver completion"}
    except (OSError, ValueError):
        rc = rc or 1
        status = {"phase": phase, "reason": f"missing or invalid solver status; see solve-{case}.log"}
    try:
        for name in ("claude-branch", "pr-number", "pr-description.md"):
            if (source / name).is_file():
                shutil.copyfile(source / name, shared / f"{case}.{name}")
        if (source / "claude-otel.jsonl").is_file():
            shutil.copyfile(source / "claude-otel.jsonl", otel / f"{case}.claude-otel.jsonl")
        if rc == 0 and any(not (shared / f"{case}.{name}").is_file() or
                           not (shared / f"{case}.{name}").read_text().strip()
                           for name in ("claude-branch", "pr-number")):
            raise ValueError("solver returned success without publication metadata")
    except (OSError, ValueError) as error:
        rc = rc or 1
        status = {"phase": "handoff", "reason": str(error)}
else:
    rc = rc or 1
status.update(case=case, status="passed" if rc == 0 else "failed", exit_code=rc)
status["reason"] = status.get("reason", f"case exited during {phase}")[:2000]
payload = json.dumps(status, indent=2) + "\n"
(artifacts / f"solve-{case}.json").write_text(payload)
(shared / f"{case}.solve-status.json").write_text(payload)
sys.exit(rc)
CASE_STATUS_PY
            exit "$?"
        }
        trap finish_case EXIT
        BASE_BRANCH=$(cat "${REAL_SHARED_DIR}/${case_name}.eval-base-branch")
        # Build a per-case SHARED_DIR with standard filenames
        CASE_SHARED=$(mktemp -d)
        for f in jira-issue-key jira-issue.json eval-base-branch eval-expected-branch eval-case; do
            cp "${REAL_SHARED_DIR}/${case_name}.${f}" "${CASE_SHARED}/${f}"
        done
        cp "${REAL_SHARED_DIR}/gh-fork-token" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/gh-upstream-token" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/trt-telemetry.sh" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/trt-runtime-policy.sh" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/github-app-auth.sh" "${CASE_SHARED}/"
        cp "${REAL_SHARED_DIR}/github-app-token-outputs" "${CASE_SHARED}/"

        cp -r "${TEMPLATE_DIR}" "${CASE_WORKDIR}"
        cd "${CASE_WORKDIR}"
        git fetch origin "${BASE_BRANCH}"
        git checkout "${BASE_BRANCH}"

        export SHARED_DIR="${CASE_SHARED}"
        export WORKDIR="${CASE_WORKDIR}"
        export EVAL_MODE=true
        CASE_PHASE=solve
        /opt/scripts/solve.sh
        CASE_PHASE=handoff
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
    status_file="${REAL_SHARED_DIR}/${case_name}.solve-status.json"
    if [[ ! -s "${status_file}" ]]; then
        jq -n --arg case "${case_name}" \
            '{case: $case, status: "failed", phase: "dispatch", exit_code: 1,
              reason: "case process ended without recording status"}' > "${status_file}"
        cp "${status_file}" "${ARTIFACT_DIR}/solve-${case_name}.json"
    fi
    result=$(jq -r '.status // "failed"' "${status_file}")
    if [[ "${result}" == "passed" ]]; then
        echo "  [PASS] ${case_name}"
    else
        echo "  [FAIL] ${case_name}: $(jq -r '.reason' "${status_file}") (see solve-${case_name}.log)"
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
    if jq -e '.rows[0].model' "${METRICS_TMP}" >/dev/null 2>&1; then
        jq --argjson failures "${FAILURES}" '
          .rows[0] as $r
          | ($r.total_cost_usd | tonumber) as $cost
          | {
              model: $r.model,
              agent: "claude-code",
              agent_version: $r.claude_code_version,
              duration_s: (($r.duration_ms | tonumber) / 1000),
              cost_usd: $cost,
              num_turns: ($r.num_turns | tonumber),
                exit_code: (if $failures > 0 then 1 else ($r.is_error | tonumber) end),
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
