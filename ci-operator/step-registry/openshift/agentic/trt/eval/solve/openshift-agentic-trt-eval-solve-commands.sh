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
METRICS_TEMP_FILES=()
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
    rm -f "${METRICS_TEMP_FILES[@]}"
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
SOLVE_STARTED_AT=$(date +%s)

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

# Keep a combined OTEL artifact for compatibility, but extract each case
# independently. Harness scoring consumes per-case metrics; using the combined
# total as a fallback for every case multiplies cost by the number of cases.
OTEL_COMBINED="${OTEL_DIR}/claude-otel.jsonl"
: > "${OTEL_COMBINED}"
for case_name in "${CASE_LIST[@]}"; do
    if [[ -f "${OTEL_DIR}/${case_name}.claude-otel.jsonl" ]]; then
        cat "${OTEL_DIR}/${case_name}.claude-otel.jsonl" >> "${OTEL_COMBINED}"
    fi
done
if [[ -s "${OTEL_COMBINED}" ]]; then
    cp "${OTEL_COMBINED}" "${ARTIFACT_DIR}/claude-otel.jsonl"
else
    echo "WARNING: no OTEL JSONL collected from any case"
fi

claude_cost_status() {
    python3 - "$1" <<'PY'
import json
import math
import sys

cost_models = set()
token_models = set()


def attribute_value(value):
    """Return the scalar value from an OTLP AnyValue."""
    if not isinstance(value, dict):
        return None
    for key in ("stringValue", "intValue", "doubleValue", "boolValue"):
        if key in value:
            return value[key]
    return None


with open(sys.argv[1]) as handle:
    for line in handle:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "/v1/metrics" not in record.get("path", ""):
            continue
        for resource in (record.get("payload") or {}).get("resourceMetrics", []):
            for scope in resource.get("scopeMetrics", []):
                for metric in scope.get("metrics", []):
                    name = metric.get("name")
                    if name not in ("claude_code.cost.usage", "claude_code.token.usage"):
                        continue
                    data = metric.get("sum", metric.get("gauge", {}))
                    for point in data.get("dataPoints", []):
                        raw = point.get("asDouble", point.get("asInt"))
                        try:
                            observed = math.isfinite(float(raw))
                        except (TypeError, ValueError):
                            observed = False
                        if not observed:
                            continue
                        attrs = {
                            attr.get("key"): attribute_value(attr.get("value"))
                            for attr in point.get("attributes", [])
                            if attr.get("key")
                        }
                        model = str(attrs.get("model") or "unknown")
                        if name == "claude_code.cost.usage":
                            cost_models.add(model)
                        else:
                            token_models.add(model)
print(json.dumps({
    "observed": bool(cost_models),
    "complete": bool(cost_models and token_models.issubset(cost_models)),
}))
PY
}

PER_CASE_TMP=$(mktemp)
METRICS_TEMP_FILES+=("${PER_CASE_TMP}")
echo '{}' > "${PER_CASE_TMP}"
CONFIGURED_MODEL="${MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL:-${AGENT_MODEL:-}}"

for case_name in "${CASE_LIST[@]}"; do
    CASE_RESULT_TMP=$(mktemp)
    METRICS_TEMP_FILES+=("${CASE_RESULT_TMP}")
    CASE_EXIT_CODE=1
    if [[ "$(cat "${RESULTS_DIR}/${case_name}" 2>/dev/null || true)" == "pass" ]]; then
        CASE_EXIT_CODE=0
    fi
    CASE_OTEL="${OTEL_DIR}/${case_name}.claude-otel.jsonl"
    METRICS_TMP=$(mktemp)
    METRICS_TEMP_FILES+=("${METRICS_TMP}")
    CODEX_USAGE='{"cost_from_metric":false,"models":{}}'
    CLAUDE_COST_STATUS='{"observed":false,"complete":false}'

    if [[ -s "${CASE_OTEL}" ]]; then
        if ! python3 /opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py \
            "${CASE_OTEL}" "${METRICS_TMP}"; then
            echo "WARNING: metrics extraction failed for ${case_name}"
        fi
        if ! CODEX_USAGE=$(
            # Source the generated shared implementation rather than carrying
            # an eval-only Codex parser. Remove the source-time prompt file in
            # this subshell; eval metrics never need prompt handoff.
            # shellcheck disable=SC1091
            source "${REAL_SHARED_DIR}/trt-telemetry.sh"
            usage=""
            usage_status=0
            usage=$(codex_otel_usage "${CASE_OTEL}") || usage_status=$?
            rm -f "${SESSION_PROMPT_FILE}"
            [[ ${usage_status} -eq 0 ]] || exit "${usage_status}"
            printf '%s\n' "${usage}"
        ); then
            CODEX_USAGE='{"cost_from_metric":false,"models":{}}'
        fi
        CLAUDE_COST_STATUS=$(claude_cost_status "${CASE_OTEL}")
    fi

    # extract_metrics rejects a malformed OTEL line before writing rows, while
    # codex_otel_usage deliberately skips malformed lines. Normalize empty or
    # invalid extractor output so an observed Codex model remains recoverable.
    if ! jq -e 'type == "object" and (.rows | type == "array")' \
        "${METRICS_TMP}" >/dev/null 2>&1; then
        printf '{"rows":[]}\n' > "${METRICS_TMP}"
    fi
    if ! jq -e 'type == "object" and ((.models // {}) | type == "object")' \
        <<< "${CODEX_USAGE}" >/dev/null 2>&1; then
        CODEX_USAGE='{"cost_from_metric":false,"models":{}}'
    fi

    if jq -e '(.rows[0] | type == "object")' "${METRICS_TMP}" >/dev/null 2>&1 \
        || jq -e '(.models // {} | length) > 0' <<< "${CODEX_USAGE}" >/dev/null 2>&1; then
        jq --arg configured "${CONFIGURED_MODEL}" \
           --argjson usage "${CODEX_USAGE}" \
           --argjson claude_cost_status "${CLAUDE_COST_STATUS}" \
           --argjson exit_code "${CASE_EXIT_CODE}" '
          def number_or_zero: try tonumber catch 0;
          def first_nonempty: map(select(type == "string" and length > 0)) | first // "";
          ((.rows[0] | type) == "object") as $has_row
          | (if $has_row then .rows[0] else {} end) as $r
          | ($usage.models // {}) as $models
          | (($models | length) > 0) as $is_codex
          | (if $is_codex
             then ($usage.cost_from_metric == true)
             else ($claude_cost_status.observed == true) end) as $cost_any_observed
          | (if $is_codex
             then (($usage.cost_from_metric == true) and ([$models[] | has("cost")] | all))
             else ($claude_cost_status.complete == true) end) as $cost_observed
          | (if ($models | has($configured)) then $configured
             elif ($r.model | type == "string" and length > 0) then $r.model
             elif ($models | length) > 0 then
               ($models | to_entries | max_by((.value.input // 0) + (.value.cache_read // 0)) | .key)
             elif ($configured | length) > 0 then $configured
             else "unknown" end) as $model
          | (if $is_codex then "codex" else "claude-code" end) as $harness
          | (if $is_codex
             then ([$usage.version, $r.codex_version, $r.claude_code_version] | first_nonempty)
             else ([$r.claude_code_version] | first_nonempty) end) as $version
          | (if $is_codex
             then ([$models[] | .turns // 0] | add // 0)
             else ($r.num_turns | number_or_zero) end) as $turns
          | (if $is_codex
             then {
               input: ([$models[] | .input // 0] | add // 0),
               output: ([$models[] | .output // 0] | add // 0),
               cache_read: ([$models[] | .cache_read // 0] | add // 0),
               cache_create: ([$models[] | .cache_create // 0] | add // 0)
             }
             else {
               input: ($r.input_tokens | number_or_zero),
               output: ($r.output_tokens | number_or_zero),
               cache_read: ($r.cache_read_input_tokens | number_or_zero),
               cache_create: ($r.cache_creation_input_tokens | number_or_zero)
             } end) as $tokens
          | (if $cost_any_observed
             then (((if $is_codex
                      then ([$models[] | .cost // 0] | add // 0)
                      else ($r.total_cost_usd | number_or_zero) end) * 1000000
                    | round) / 1000000)
             else 0 end) as $observed_cost
          | (if $cost_observed then $observed_cost else null end) as $cost
          | (if $is_codex
             then ($models | to_entries | map({
               key: .key,
               value: {
                 input: (.value.input // 0),
                 output: (.value.output // 0),
                 cache_read: (.value.cache_read // 0),
                 cache_create: (.value.cache_create // 0),
                 cost_observed: (.value | has("cost")),
                 cost_usd: (if (.value | has("cost")) then .value.cost else null end),
                 observed_cost_usd: (.value.cost // 0)
               }
             }) | from_entries)
             else {($model): ($tokens + {
               cost_observed: $cost_observed,
               cost_usd: $cost,
               observed_cost_usd: $observed_cost
             })} end) as $per_model
          | (if $is_codex
             then ($models | to_entries | map({key: .key, value: (.value.turns // 0)}) | from_entries)
             else {($model): $turns} end) as $per_model_turns
          | {
              model: $model,
              agent: $harness,
              agent_version: $version,
              duration_s: (if $has_row then (($r.duration_ms | number_or_zero) / 1000) else null end),
              cost_observed: $cost_observed,
              cost_usd: $cost,
              observed_cost_usd: $observed_cost,
              num_turns: $turns,
              exit_code: $exit_code,
              token_usage: $tokens,
              per_model_usage: $per_model,
              per_model_turns: $per_model_turns
            }
        ' "${METRICS_TMP}" > "${CASE_RESULT_TMP}"
    else
        jq -n --arg model "${CONFIGURED_MODEL:-unknown}" \
              --argjson exit_code "${CASE_EXIT_CODE}" '{
          model: $model,
          agent: (if ($model | startswith("gpt-")) then "codex" else "claude-code" end),
          agent_version: "",
          duration_s: null,
          cost_observed: false,
          cost_usd: null,
          observed_cost_usd: 0,
          num_turns: null,
          exit_code: $exit_code,
          token_usage: null,
          per_model_usage: {},
          per_model_turns: {}
        }' > "${CASE_RESULT_TMP}"
        echo "WARNING: no usable metrics row or Codex usage for ${case_name}"
    fi

    jq --arg case_name "${case_name}" --slurpfile result "${CASE_RESULT_TMP}" \
        '. + {($case_name): $result[0]}' "${PER_CASE_TMP}" > "${PER_CASE_TMP}.next"
    mv "${PER_CASE_TMP}.next" "${PER_CASE_TMP}"
    rm -f "${METRICS_TMP}" "${CASE_RESULT_TMP}"
done

WALL_CLOCK_S=$(( $(date +%s) - SOLVE_STARTED_AT ))
RUN_RESULT_TMP=$(mktemp)
METRICS_TEMP_FILES+=("${RUN_RESULT_TMP}")
python3 - "${PER_CASE_TMP}" "${RUN_RESULT_TMP}" "${CONFIGURED_MODEL}" "${WALL_CLOCK_S}" <<'PY'
import json
import math
import sys

per_case_path, output_path, configured_model, wall_clock = sys.argv[1:]
with open(per_case_path) as handle:
    per_case = json.load(handle)

token_keys = ("input", "output", "cache_read", "cache_create")
token_usage = {key: 0 for key in token_keys}
per_model_usage = {}
per_model_turns = {}
duration = 0.0
num_turns = 0
exit_code = 0
unknown_cost_cases = []
observed_costs = []

for case_name, result in per_case.items():
    exit_code = max(exit_code, int(result.get("exit_code") or 0))
    if isinstance(result.get("duration_s"), (int, float)):
        duration += result["duration_s"]
    if isinstance(result.get("num_turns"), (int, float)):
        num_turns += result["num_turns"]
    for key in token_keys:
        value = (result.get("token_usage") or {}).get(key)
        if isinstance(value, (int, float)):
            token_usage[key] += value
    if isinstance(result.get("observed_cost_usd"), (int, float)):
        observed_costs.append(result["observed_cost_usd"])
    if result.get("cost_observed") is not True:
        unknown_cost_cases.append(case_name)
    for model, usage in (result.get("per_model_usage") or {}).items():
        aggregate = per_model_usage.setdefault(model, {
            **{key: 0 for key in token_keys},
            "cost_observed": True,
            "observed_cost_usd": 0.0,
        })
        for key in token_keys:
            value = usage.get(key)
            if isinstance(value, (int, float)):
                aggregate[key] += value
        if isinstance(usage.get("observed_cost_usd"), (int, float)):
            aggregate["observed_cost_usd"] += usage["observed_cost_usd"]
        if usage.get("cost_observed") is not True:
            aggregate["cost_observed"] = False
    for model, turns in (result.get("per_model_turns") or {}).items():
        if isinstance(turns, (int, float)):
            per_model_turns[model] = per_model_turns.get(model, 0) + turns

for usage in per_model_usage.values():
    usage["observed_cost_usd"] = round(usage["observed_cost_usd"], 6)
    usage["cost_usd"] = usage["observed_cost_usd"] if usage["cost_observed"] else None

# A case without observed cost may have no model metadata at all. In that
# situation no per-model total spans the complete run, so retain only the
# explicitly labelled observed partial rather than presenting it as total.
if unknown_cost_cases:
    for usage in per_model_usage.values():
        usage["cost_observed"] = False
        usage["cost_usd"] = None

if configured_model in per_model_usage:
    model = configured_model
elif per_model_usage:
    model = max(per_model_usage, key=lambda name: (
        per_model_usage[name]["input"] + per_model_usage[name]["cache_read"]
    ))
else:
    model = configured_model or "unknown"

matching = [result for result in per_case.values() if result.get("model") == model]
agent = (matching[0].get("agent") if matching else None) or (
    "codex" if model.startswith("gpt-") else "claude-code"
)
agent_version = next((
    result.get("agent_version", "") for result in matching if result.get("agent_version")
), "")
observed_cost = round(math.fsum(observed_costs), 6)
cost_complete = not unknown_cost_cases
run_result = {
    "model": model,
    "agent": agent,
    "agent_version": agent_version,
    "execution_mode": "case",
    "num_cases": len(per_case),
    "duration_s": round(duration, 3),
    "wall_clock_s": int(wall_clock),
    "cost_observed": cost_complete,
    "cost_usd": observed_cost if cost_complete else None,
    "observed_cost_usd": observed_cost,
    "cost_unobserved_cases": unknown_cost_cases,
    "num_turns": num_turns,
    "exit_code": exit_code,
    "token_usage": token_usage,
    "per_model_usage": per_model_usage,
    "per_model_turns": per_model_turns,
    "per_case": per_case,
}
with open(output_path, "w") as handle:
    json.dump(run_result, handle, indent=2, allow_nan=False)
    handle.write("\n")
PY

mv "${RUN_RESULT_TMP}" "${REAL_SHARED_DIR}/eval-solve-run-result.json"
cp "${REAL_SHARED_DIR}/eval-solve-run-result.json" "${ARTIFACT_DIR}/eval-solve-run-result.json"
rm -f "${PER_CASE_TMP}"

# Always exit 0 so the judge step runs and produces the eval summary.
# The judge determines pass/fail based on check results.
echo "=== TRT Eval Solve Complete ==="
