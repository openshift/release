#!/bin/bash
#
# Run agent-eval-harness against Claude Code skills.
#
# Required env:
#   EVAL_CONFIG  -- path to eval.yaml (relative to repo root)
#
# Optional env:
#   EVAL_MODEL        -- model for the skill under test (default: claude-sonnet-4-6)
#   EVAL_EFFORT       -- agent reasoning effort passed to /eval-run as --effort
#   EVAL_PARALLELISM  -- number of test cases to run concurrently (default: 1)
#   EVAL_CASES        -- comma-separated list of case IDs to run (default: all)
#   EVAL_DISCOVER     -- "true" or glob pattern to auto-discover eval configs
#   EVAL_BASELINE     -- run-id of a previous run to compare against
#   EVAL_EXTRA_ARGS   -- additional args passed to /eval-run
#   EVAL_SETUP_SCRIPT -- script to run before eval (e.g. snapshot extraction)
#   CLAUDE_MODEL      -- model for the eval harness orchestrator (default: claude-sonnet-4-6)
#   EVAL_MAX_TURNS    -- max conversation turns for the orchestrator (default: 100)

set -o nounset
set -o errexit
set -o pipefail

echo "Starting claude-agent-eval"

# --- Gangway override ---
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_EVAL_MODEL:-}" ]]; then
    echo "Applying Gangway override: EVAL_MODEL=${MULTISTAGE_PARAM_OVERRIDE_EVAL_MODEL}"
    EVAL_MODEL="${MULTISTAGE_PARAM_OVERRIDE_EVAL_MODEL}"
fi
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_EVAL_EFFORT:-}" ]]; then
    echo "Applying Gangway override: EVAL_EFFORT=${MULTISTAGE_PARAM_OVERRIDE_EVAL_EFFORT}"
    EVAL_EFFORT="${MULTISTAGE_PARAM_OVERRIDE_EVAL_EFFORT}"
fi

# Load GitHub token for gh CLI access (same secret as payload-agent)
set +x
if [ -f "${GITHUB_TOKEN_PATH:-}" ]; then
    export GITHUB_TOKEN
    GITHUB_TOKEN=$(cat "${GITHUB_TOKEN_PATH}")
    echo "GitHub token loaded."
else
    echo "Warning: GitHub token not found at ${GITHUB_TOKEN_PATH:-<unset>}. gh CLI will run unauthenticated."
fi

cd "${EVAL_WORKDIR:-/opt/ai-helpers}"

echo "Skill model: ${EVAL_MODEL}"

# -----------------------------------------------------------------------
# Build list of eval configs to run (single or discovery mode)
# -----------------------------------------------------------------------
CONFIGS_TO_RUN=()
if [[ -n "${EVAL_DISCOVER}" ]]; then
    if [[ -n "${EVAL_CONFIG}" ]] && [[ "${EVAL_CONFIG}" != "eval.yaml" ]]; then
        echo "ERROR: EVAL_DISCOVER and EVAL_CONFIG are mutually exclusive"
        exit 1
    fi

    # Default discovery pattern: all YAML files directly under */evals/ directories
    DISCOVER_PATTERN="${EVAL_DISCOVER}"
    if [[ "${EVAL_DISCOVER}" == "true" ]]; then
        DISCOVER_PATTERN="plugins/*/evals/*.yaml"
    fi

    echo "=== Discovering eval configs: ${DISCOVER_PATTERN} ==="
    while IFS= read -r config; do
        [[ -n "${config}" ]] && CONFIGS_TO_RUN+=("${config}")
    done < <(find . -path "./${DISCOVER_PATTERN}" -name '*.yaml' ! -path '*/cases/*' | sed 's|^\./||' | sort)

    echo "Found ${#CONFIGS_TO_RUN[@]} eval config(s):"
    printf '  %s\n' "${CONFIGS_TO_RUN[@]}"

    if [[ ${#CONFIGS_TO_RUN[@]} -eq 0 ]]; then
        echo "No eval configs found matching ${DISCOVER_PATTERN}"
        exit 0
    fi

    # Filter to only changed evals when EVAL_CHANGED_ONLY is set
    if [[ "${EVAL_CHANGED_ONLY:-}" == "true" ]] && [[ -n "${PULL_BASE_SHA:-}" ]]; then
        echo ""
        echo "=== Filtering to changed evals ==="
        CHANGED_FILES=$(git diff --name-only "${PULL_BASE_SHA}...HEAD" || true)

        FILTERED=()
        for config in "${CONFIGS_TO_RUN[@]}"; do
            config_name=$(basename "${config}" .yaml)
            config_dir=$(dirname "${config}")

            if echo "${CHANGED_FILES}" | grep -qE "(${config}|${config_dir}/${config_name}/|skills/${config_name}/)"; then
                echo "  MATCH: ${config}"
                FILTERED+=("${config}")
            fi
        done

        if [[ ${#FILTERED[@]} -eq 0 ]]; then
            echo "No eval configs affected by changes, skipping."
            exit 0
        fi
        CONFIGS_TO_RUN=("${FILTERED[@]}")
    fi
else
    echo "Config: ${EVAL_CONFIG}"
    if [[ ! -f "${EVAL_CONFIG}" ]]; then
        echo "ERROR: EVAL_CONFIG not found at ${EVAL_CONFIG}"
        exit 1
    fi
    CONFIGS_TO_RUN=("${EVAL_CONFIG}")
fi

# -----------------------------------------------------------------------
# Install plugins
# -----------------------------------------------------------------------
echo ""
echo "=== Installing plugins ==="
EVAL_HARNESS_DIR="/tmp/agent-eval-harness"
# EVAL_HARNESS_REPO / EVAL_HARNESS_REF let a PR rehearse the eval against a
# not-yet-merged branch of the harness. They default to the released main.
EVAL_HARNESS_REPO="${EVAL_HARNESS_REPO:-https://github.com/opendatahub-io/agent-eval-harness.git}"
git clone --depth 1 ${EVAL_HARNESS_REF:+--branch "${EVAL_HARNESS_REF}"} "${EVAL_HARNESS_REPO}" "${EVAL_HARNESS_DIR}"
echo "agent-eval-harness cloned from ${EVAL_HARNESS_REPO} (ref: ${EVAL_HARNESS_REF:-default})."

# -----------------------------------------------------------------------
# Run optional setup script (e.g. extract snapshots, populate fixtures)
# -----------------------------------------------------------------------
if [[ -n "${EVAL_SETUP_SCRIPT}" ]]; then
    if [[ ! -f "${EVAL_SETUP_SCRIPT}" ]]; then
        echo "ERROR: EVAL_SETUP_SCRIPT not found: ${EVAL_SETUP_SCRIPT}"
        exit 1
    fi
    echo ""
    echo "=== Running setup script: ${EVAL_SETUP_SCRIPT} ==="
    EVAL_SNAPSHOT_DIR=$(bash "${EVAL_SETUP_SCRIPT}")
    export EVAL_SNAPSHOT_DIR
    echo "Snapshot dir: ${EVAL_SNAPSHOT_DIR}"
fi

# -----------------------------------------------------------------------
# Artifact copy trap
# -----------------------------------------------------------------------
copy_artifacts() {
    echo "Copying eval artifacts..."
    RUNS_DIR="${AGENT_EVAL_RUNS_DIR:-eval/runs}"
    if [[ -d "${RUNS_DIR}" ]]; then
        find "${RUNS_DIR}" -name "report.html" -exec cp {} "${ARTIFACT_DIR}/eval-report-summary.html" \; 2>/dev/null || true
        find "${RUNS_DIR}" -name "summary.yaml" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
        find "${RUNS_DIR}" -name "run_result.json" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
        tar -czf "${ARTIFACT_DIR}/eval-runs.tar.gz" "${RUNS_DIR}/" 2>/dev/null || true
    fi

    CLAUDE_HOME="/home/claude/.claude"
    if [[ -d "${CLAUDE_HOME}/projects" ]]; then
        tar -czf "${ARTIFACT_DIR}/claude-sessions.tar.gz" \
            -C "${CLAUDE_HOME}" projects/ 2>/dev/null || true
    fi
}
trap copy_artifacts EXIT TERM INT

# -----------------------------------------------------------------------
# Workaround: --continue + -p is broken (anthropics/claude-code#42376).
# -----------------------------------------------------------------------
export CLAUDE_CODE_ENTRYPOINT=sdk-cli

# -----------------------------------------------------------------------
# Build common arguments and run evals
# -----------------------------------------------------------------------
ALLOWED_TOOLS="Bash Read Write Edit Grep Glob Agent Skill"
OVERALL_EXIT=0
JUNIT_TESTCASES=""
TOTAL_DURATION=0
FAILURE_COUNT=0
CONFIGS_RUN=0
JUNIT_FILE="${ARTIFACT_DIR}/junit_claude-eval.xml"
STEP_START=${SECONDS}
STEP_TIMEOUT=13800  # 3h50m — leave margin within the 4h step limit

write_junit() {
    cat > "${JUNIT_FILE}" <<JEOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="claude-eval" tests="${CONFIGS_RUN}" failures="${FAILURE_COUNT}" time="${TOTAL_DURATION}">
${JUNIT_TESTCASES}
</testsuite>
JEOF
}

write_eval_metrics() {
    local stream_log="$1"
    local eval_result="$2"
    local run_id="$3"
    local prompt="$4"
    local extractor="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
    local output="${ARTIFACT_DIR}/claude-session-metrics-autodl.json"

    if [[ ! -f "${extractor}" ]]; then
        echo "WARNING: ${extractor} not found; cannot extract eval metrics."
        return 1
    fi

    python3 - "${extractor}" "${stream_log}" "${eval_result}" "${output}" \
        "${BUILD_ID:-unknown}" "${run_id}" "${prompt}" <<'PYEOF'
import datetime
import importlib.util
import json
import pathlib
import sys
from collections import Counter

extractor_path, stream_path, result_path, output_path, build_id, run_id, prompt = sys.argv[1:]

spec = importlib.util.spec_from_file_location("extract_metrics", extractor_path)
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
analyzed_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rows = []


def empty_row():
    return {
        key: "" if field_type == "string" else "0"
        for key, field_type in metrics.SCHEMA.items()
    }


def add_orchestrator_rows():
    stream_file = pathlib.Path(stream_path)
    if not stream_file.is_file():
        return

    init = None
    result = None
    seen_tools = set()
    tool_counts = Counter()
    skills = []
    files_written = 0
    thinking_blocks = 0
    agent_tools = 0
    with stream_file.open(errors="replace") as stream:
        for line in stream:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("type") == "system" and record.get("subtype") == "init" and init is None:
                init = record
            if record.get("type") == "result":
                result = record
            if record.get("type") != "assistant":
                continue
            content = record.get("message", {}).get("content", [])
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "thinking":
                    thinking_blocks += 1
                    continue
                if block.get("type") != "tool_use":
                    continue
                tool_id = str(block.get("id", ""))
                if tool_id and tool_id in seen_tools:
                    continue
                if tool_id:
                    seen_tools.add(tool_id)
                tool_name = str(block.get("name", ""))
                if not tool_name:
                    continue
                tool_counts[tool_name] += 1
                tool_input = block.get("input", {})
                if not isinstance(tool_input, dict):
                    tool_input = {}
                if tool_name == "Skill":
                    skill = str(tool_input.get("skill", ""))
                    if skill:
                        skills.append(skill)
                elif tool_name == "Write":
                    files_written += 1
                elif tool_name == "Agent":
                    agent_tools += 1

    if init is None or result is None:
        return
    model_usages = result.get("modelUsage", {})
    if not isinstance(model_usages, dict) or not model_usages:
        usage = result.get("usage", {})
        if not isinstance(usage, dict):
            usage = {}
        model_usages = {
            init.get("model", "unknown"): {
                "inputTokens": usage.get("input_tokens", 0),
                "outputTokens": usage.get("output_tokens", 0),
                "cacheReadInputTokens": usage.get("cache_read_input_tokens", 0),
                "cacheCreationInputTokens": usage.get("cache_creation_input_tokens", 0),
                "costUSD": result.get("total_cost_usd", 0),
            }
        }
    total_cost = sum(float(usage.get("costUSD", 0) or 0) for usage in model_usages.values())
    primary_model = str(init.get("model", ""))
    plugins = ",".join(
        str(plugin.get("name", ""))
        for plugin in init.get("plugins", [])
        if isinstance(plugin, dict) and plugin.get("name")
    )
    for model, usage in model_usages.items():
        cost = float(usage.get("costUSD", 0) or 0)
        duration_ratio = cost / total_cost if total_cost else 1 / len(model_usages)
        input_tokens = int(usage.get("inputTokens", 0) or 0)
        output_tokens = int(usage.get("outputTokens", 0) or 0)
        cache_read = int(usage.get("cacheReadInputTokens", 0) or 0)
        cache_create = int(usage.get("cacheCreationInputTokens", 0) or 0)
        total_input = input_tokens + cache_read + cache_create
        cache_hit_rate = cache_read / total_input * 100 if total_input else 0
        is_primary = str(model) == primary_model
        session_id = str(result.get("session_id") or init.get("session_id", ""))
        if len(model_usages) > 1:
            session_id = f"{session_id}:{model}"
        row = empty_row()
        row.update({
            "session_id": session_id,
            "model": str(model),
            "claude_code_version": str(init.get("claude_code_version", "")),
            "permission_mode": str(init.get("permissionMode", "")),
            "entrypoint": "sdk-cli",
            "prompt": prompt[:500],
            "plugins_loaded": plugins,
            "analyzed_at": analyzed_at,
            "duration_ms": str(int(int(result.get("duration_ms", 0) or 0) * duration_ratio)),
            "duration_api_ms": str(int(int(result.get("duration_api_ms", 0) or 0) * duration_ratio)),
            "ttft_ms": str(int(result.get("ttft_ms", 0) or 0) if is_primary else 0),
            "num_turns": str(int(result.get("num_turns", 0) or 0) if is_primary else 0),
            "total_cost_usd": f"{cost:.6f}",
            "input_tokens": str(input_tokens),
            "output_tokens": str(output_tokens),
            "cache_read_input_tokens": str(cache_read),
            "cache_creation_input_tokens": str(cache_create),
            "cache_hit_rate_pct": f"{cache_hit_rate:.1f}",
            "total_tool_calls": str(sum(tool_counts.values()) if is_primary else 0),
            "tool_call_breakdown": json.dumps(dict(tool_counts.most_common())) if is_primary else "{}",
            "skills_invoked": ",".join(dict.fromkeys(skills)) if is_primary else "",
            "files_written": str(files_written if is_primary else 0),
            "num_thinking_blocks": str(thinking_blocks if is_primary else 0),
            "num_subagents": str(agent_tools if is_primary else 0),
            "is_error": "1" if result.get("is_error", False) else "0",
            "terminal_reason": str(result.get("terminal_reason", "")),
            "stop_reason": str(result.get("stop_reason", "")),
        })
        rows.append(row)


def add_harness_rows():
    result_file = pathlib.Path(result_path) if result_path else None
    if result_file is None or not result_file.is_file():
        return
    with result_file.open() as stream:
        result = json.load(stream)
    usages = result.get("per_model_usage", {})
    if not isinstance(usages, dict) or not usages:
        model = result.get("model", "unknown")
        usage = result.get("token_usage", {})
        if not isinstance(usage, dict):
            usage = {}
        usages = {model: {**usage, "cost_usd": result.get("cost_usd", 0)}}
    model_turns = result.get("per_model_turns", {})
    if not isinstance(model_turns, dict):
        model_turns = {}
    total_turns = sum(int(value or 0) for value in model_turns.values())
    total_cost = sum(float(usage.get("cost_usd", 0) or 0) for usage in usages.values())
    duration_s = float(result.get("duration_s", 0) or result.get("wall_clock_s", 0) or 0)
    if not duration_s:
        per_case = result.get("per_case", {})
        cases = per_case.values() if isinstance(per_case, dict) else per_case if isinstance(per_case, list) else []
        duration_s = sum(
            float(case.get("duration_s", 0) or 0)
            for case in cases
            if isinstance(case, dict)
        )
    duration_ms = max(1, int(duration_s * 1000))
    eval_params = result.get("eval_params", {})
    if not isinstance(eval_params, dict):
        eval_params = {}
    skill = str(eval_params.get("skill", ""))
    skill_args = str(eval_params.get("skill_args", ""))
    harness_prompt = f"/{skill} {skill_args}".strip() if skill else prompt

    for model, usage in usages.items():
        turns = int(model_turns.get(model, 0) or 0)
        cost = float(usage.get("cost_usd", 0) or 0)
        input_tokens = int(usage.get("input", 0) or 0)
        output_tokens = int(usage.get("output", 0) or 0)
        cache_read = int(usage.get("cache_read", 0) or 0)
        cache_create = int(usage.get("cache_creation", 0) or 0)
        total_input = input_tokens + cache_read + cache_create
        if cost <= 0 and total_input <= 0 and output_tokens <= 0 and turns <= 0:
            continue
        if total_turns:
            duration_ratio = turns / total_turns
        elif total_cost:
            duration_ratio = cost / total_cost
        else:
            duration_ratio = 1 / len(usages)
        cache_hit_rate = cache_read / total_input * 100 if total_input else 0
        exit_code = int(result.get("exit_code", 0) or 0)
        row = empty_row()
        row.update({
            "session_id": f"eval-harness:{build_id}:{run_id}:{model}",
            "model": str(model),
            "claude_code_version": str(result.get("agent_version", "")).split(" ", 1)[0],
            "permission_mode": "default",
            "entrypoint": "agent-eval-harness",
            "prompt": harness_prompt[:500],
            "plugins_loaded": "agent-eval-harness",
            "analyzed_at": analyzed_at,
            "duration_ms": str(max(1, int(duration_ms * duration_ratio))),
            "num_turns": str(turns or int(result.get("num_turns", 0) or 0)),
            "total_cost_usd": f"{cost:.6f}",
            "input_tokens": str(input_tokens),
            "output_tokens": str(output_tokens),
            "cache_read_input_tokens": str(cache_read),
            "cache_creation_input_tokens": str(cache_create),
            "cache_hit_rate_pct": f"{cache_hit_rate:.1f}",
            "tool_call_breakdown": "{}",
            "skills_invoked": skill,
            "is_error": "1" if exit_code else "0",
            "terminal_reason": "eval_failed" if exit_code else "eval_complete",
            "stop_reason": "eval_failed" if exit_code else "end_turn",
        })
        rows.append(row)


add_orchestrator_rows()
add_harness_rows()
if not rows:
    sys.exit(1)

output = pathlib.Path(output_path)
if output.is_file():
    try:
        with output.open() as stream:
            document = json.load(stream)
    except (json.JSONDecodeError, OSError) as error:
        raise RuntimeError(f"cannot read existing AutoDL artifact: {error}") from error
    if not isinstance(document, dict) or document.get("schema") != metrics.SCHEMA:
        raise RuntimeError("existing AutoDL artifact has an incompatible schema")
    existing_rows = document.setdefault("rows", [])
    if not isinstance(existing_rows, list):
        raise RuntimeError("existing AutoDL artifact rows must be a list")
    existing_rows.extend(rows)
else:
    document = metrics.build_autodl(rows[0])
    document["rows"] = rows
temporary = output.with_suffix(output.suffix + ".tmp")
with temporary.open("w") as stream:
    json.dump(document, stream, indent=4)
temporary.replace(output)
print(f"Wrote {len(rows)} eval metric row(s) to {output}")
PYEOF
}

for config in "${CONFIGS_TO_RUN[@]}"; do
    ELAPSED=$(( SECONDS - STEP_START ))
    if [[ ${ELAPSED} -ge ${STEP_TIMEOUT} ]]; then
        echo "WARNING: approaching step timeout (${ELAPSED}s elapsed), skipping remaining configs."
        break
    fi
    config_name=$(echo "${config}" | sed 's|\.yaml$||' | tr '/' '-')
    config_basename=$(basename "${config}" .yaml)
    echo ""
    echo "========================================"
    echo "=== Running eval: ${config_name} ==="
    echo "========================================"

    RUN_ID="ci-$(date +%Y%m%d-%H%M%S)-${config_name}-${EVAL_MODEL}"

    # Per-config changed-case detection
    CASE_ARGS=""
    if [[ "${EVAL_CHANGED_ONLY:-}" == "true" ]] && [[ -n "${PULL_BASE_SHA:-}" ]]; then
        # In discovery mode, derive cases dir from config path convention
        if [[ -n "${EVAL_DISCOVER}" ]]; then
            CASES_DIR="$(dirname "${config}")/${config_basename}/cases"
        elif [[ -n "${EVAL_CASES_DIR}" ]]; then
            CASES_DIR="${EVAL_CASES_DIR}"
        else
            CASES_DIR=""
        fi

        if [[ -n "${CASES_DIR}" ]] && [[ -d "${CASES_DIR}" ]]; then
            if CASE_CHANGES=$(git diff --name-only "${PULL_BASE_SHA}...HEAD" -- "${CASES_DIR}"); then
                if [[ -n "${CASE_CHANGES}" ]]; then
                    DETECTED=$(echo "${CASE_CHANGES}" | sed "s|^${CASES_DIR}/||" | cut -d'/' -f1 | sort -u | paste -sd, -)
                    echo "Changed cases: ${DETECTED}"
                    CASE_ARGS="--cases ${DETECTED//,/ }"
                fi
            fi
        fi
    fi

    # Skip configs with no changed cases in changed-only mode
    if [[ "${EVAL_CHANGED_ONLY:-}" == "true" ]] && [[ -z "${CASE_ARGS}" ]] && [[ -z "${EVAL_CASES}" ]]; then
        echo "No changed cases for ${config_name}, skipping."
        continue
    fi

    # Include explicit EVAL_CASES if set (single-config mode)
    if [[ -z "${CASE_ARGS}" ]] && [[ -n "${EVAL_CASES}" ]]; then
        CASE_ARGS="--cases ${EVAL_CASES//,/ }"
    fi

    EVAL_RUN_ARGS="--config ${config} --model ${EVAL_MODEL} --run-id ${RUN_ID} --parallelism ${EVAL_PARALLELISM}"
    [[ -n "${EVAL_EFFORT:-}" ]] && EVAL_RUN_ARGS="${EVAL_RUN_ARGS} --effort ${EVAL_EFFORT}"
    [[ -n "${CASE_ARGS}" ]] && EVAL_RUN_ARGS="${EVAL_RUN_ARGS} ${CASE_ARGS}"
    [[ -n "${EVAL_BASELINE}" ]] && EVAL_RUN_ARGS="${EVAL_RUN_ARGS} --baseline ${EVAL_BASELINE}"
    [[ -n "${EVAL_EXTRA_ARGS}" ]] && EVAL_RUN_ARGS="${EVAL_RUN_ARGS} ${EVAL_EXTRA_ARGS}"

    echo "Run ID: ${RUN_ID}"
    echo "Args: ${EVAL_RUN_ARGS}"

    EVAL_START=$(date +%s)
    THIS_EXIT=0
    STREAM_LOG="${ARTIFACT_DIR}/claude-eval-${config_name}.log"
    timeout 12600 claude \
        --model "${CLAUDE_MODEL}" \
        --plugin-dir "${EVAL_HARNESS_DIR}" \
        --allowedTools "${ALLOWED_TOOLS}" \
        --output-format stream-json \
        --max-turns "${EVAL_MAX_TURNS}" \
        -p "/eval-run ${EVAL_RUN_ARGS}" \
        --verbose 2>&1 | tee "${STREAM_LOG}" || THIS_EXIT=$?

    EVAL_RESULT=$(find "${AGENT_EVAL_RUNS_DIR:-eval/runs}" \
        -path "*/${RUN_ID}/run_result.json" -type f -print -quit 2>/dev/null || true)
    if [[ -z "${EVAL_RESULT}" ]]; then
        echo "WARNING: eval harness did not produce run_result.json for ${config_name}"
    fi
    if ! write_eval_metrics "${STREAM_LOG}" "${EVAL_RESULT}" "${RUN_ID}" \
        "/eval-run ${EVAL_RUN_ARGS}"; then
        echo "WARNING: failed to write autodl eval metrics for ${config_name}"
    fi
    THIS_DURATION=$(( $(date +%s) - EVAL_START ))
    TOTAL_DURATION=$(( TOTAL_DURATION + THIS_DURATION ))

    TESTCASE="[sig-claude] ${config_name} evaluation"
    if [[ "${THIS_EXIT}" -ne 0 ]]; then
        OVERALL_EXIT=1
        FAILURE_COUNT=$(( FAILURE_COUNT + 1 ))
        JUNIT_TESTCASES="${JUNIT_TESTCASES}
  <testcase name=\"${TESTCASE}\" time=\"${THIS_DURATION}\">
    <failure message=\"eval-run failed (exit ${THIS_EXIT})\">eval-run exited with code ${THIS_EXIT}.</failure>
  </testcase>"
    else
        JUNIT_TESTCASES="${JUNIT_TESTCASES}
  <testcase name=\"${TESTCASE}\" time=\"${THIS_DURATION}\"/>"
    fi

    CONFIGS_RUN=$(( CONFIGS_RUN + 1 ))
    echo "=== ${config_name}: completed in ${THIS_DURATION}s (exit ${THIS_EXIT}) ==="

    write_junit
done

echo "JUnit XML written to ${JUNIT_FILE}"

if [[ "${OVERALL_EXIT}" -ne 0 ]]; then
    echo "Evaluation failed."
    exit 1
fi

echo "Evaluation complete."
