#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

extract_session_metrics() {
    local extractor="/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py"
    local metrics_dir="${SHARED_DIR}/claude-session-metrics"
    local output="${ARTIFACT_DIR}/claude-session-metrics-autodl.json"
    local temp_dir row_count
    local -a extracted=()

    if [[ ! -d "${metrics_dir}" ]]; then
        echo "No shared Claude telemetry found. Skipping metrics extraction."
        return
    fi
    if [[ ! -f "${extractor}" ]]; then
        echo "WARNING: ${extractor} not found; cannot extract session metrics."
        return
    fi

    temp_dir=$(mktemp -d)
    shopt -s nullglob
    for otel_log in "${metrics_dir}"/*.otel.jsonl; do
        local name stream_log extracted_file
        name=$(basename "${otel_log}" .otel.jsonl)
        stream_log="${metrics_dir}/${name}.stream.jsonl"
        extracted_file="${temp_dir}/${name}-autodl.json"

        local -a args=("${extractor}" "${otel_log}" "${extracted_file}")
        if [[ -s "${stream_log}" ]]; then
            args+=(--stream-log "${stream_log}")
        fi
        if python3 "${args[@]}"; then
            extracted+=("${extracted_file}")
        else
            echo "WARNING: failed to extract Claude metrics for ${name}"
        fi
    done
    shopt -u nullglob

    local eval_extracted_file="${temp_dir}/eval-harness-autodl.json"
    python3 - "${extractor}" "${metrics_dir}" "${eval_extracted_file}" "${BUILD_ID:-unknown}" <<'PYEOF'
import datetime
import importlib.util
import json
import pathlib
import sys
from collections import Counter

extractor_path, metrics_path, output_path, build_id = sys.argv[1:]
result_files = sorted(pathlib.Path(metrics_path).glob("*.eval-run.json"))
otel_names = {
    path.name.removesuffix(".otel.jsonl")
    for path in pathlib.Path(metrics_path).glob("*.otel.jsonl")
}
stream_files = [
    path
    for path in sorted(pathlib.Path(metrics_path).glob("*.stream.jsonl"))
    if path.name.removesuffix(".stream.jsonl") not in otel_names
]
if not result_files and not stream_files:
    sys.exit(0)

spec = importlib.util.spec_from_file_location("extract_metrics", extractor_path)
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)
analyzed_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rows = []

for stream_file in stream_files:
    records = []
    for line in stream_file.read_text(errors="replace").splitlines():
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    inits = [record for record in records if record.get("type") == "system" and record.get("subtype") == "init"]
    results = [record for record in records if record.get("type") == "result"]
    if not inits or not results:
        continue
    init = inits[0]
    result = results[-1]
    model_usages = result.get("modelUsage", {})
    if not model_usages:
        usage = result.get("usage", {})
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
    seen_tools = set()
    tool_counts = Counter()
    skills = []
    files_written = 0
    thinking_blocks = 0
    agent_tools = 0
    prompt = ""
    for record in records:
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
            if tool_name == "Skill":
                skill = str(tool_input.get("skill", ""))
                if skill:
                    skills.append(skill)
                    if not prompt:
                        prompt = f"/{skill} {tool_input.get('args', '')}".strip()
            elif tool_name == "Write":
                files_written += 1
            elif tool_name == "Agent":
                agent_tools += 1
    if not prompt:
        prompt = f"/eval-run {stream_file.name.removesuffix('.stream.jsonl')}"
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
        row = {
            key: "" if field_type == "string" else "0"
            for key, field_type in metrics.SCHEMA.items()
        }
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
            "ttft_ms": str(result.get("ttft_ms", 0) if is_primary else 0),
            "num_turns": str(result.get("num_turns", 0) if is_primary else 0),
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

for result_file in result_files:
    with result_file.open() as stream:
        result = json.load(stream)
    usages = result.get("per_model_usage", {})
    if not usages:
        model = result.get("model", "unknown")
        usages = {model: {**result.get("token_usage", {}), "cost_usd": result.get("cost_usd", 0)}}
    model_turns = result.get("per_model_turns", {})
    total_turns = sum(int(value or 0) for value in model_turns.values())
    total_cost = sum(float(usage.get("cost_usd", 0) or 0) for usage in usages.values())
    duration_s = float(result.get("duration_s", 0) or result.get("wall_clock_s", 0) or 0)
    if not duration_s:
        per_case = result.get("per_case", {})
        if isinstance(per_case, dict):
            duration_s = sum(
                float(case.get("duration_s", 0) or 0)
                for case in per_case.values()
                if isinstance(case, dict)
            )
    duration_ms = max(1, int(duration_s * 1000))
    eval_params = result.get("eval_params", {})
    skill = str(eval_params.get("skill", ""))
    skill_args = str(eval_params.get("skill_args", ""))
    prompt = f"/{skill} {skill_args}".strip() if skill else f"/eval-run {result_file.stem}"

    for model, usage in usages.items():
        turns = int(model_turns.get(model, 0) or 0)
        cost = float(usage.get("cost_usd", 0) or 0)
        if cost <= 0:
            continue
        if total_turns:
            duration_ratio = turns / total_turns
        elif total_cost:
            duration_ratio = cost / total_cost
        else:
            duration_ratio = 1 / len(usages)
        input_tokens = int(usage.get("input", 0) or 0)
        output_tokens = int(usage.get("output", 0) or 0)
        cache_read = int(usage.get("cache_read", 0) or 0)
        cache_create = int(usage.get("cache_create", 0) or 0)
        total_input = input_tokens + cache_read + cache_create
        cache_hit_rate = cache_read / total_input * 100 if total_input else 0
        exit_code = int(result.get("exit_code", 0) or 0)
        run_id = result_file.name.removesuffix(".eval-run.json")
        row = {
            key: "" if field_type == "string" else "0"
            for key, field_type in metrics.SCHEMA.items()
        }
        row.update({
            "session_id": f"eval-harness:{build_id}:{run_id}:{model}",
            "model": str(model),
            "claude_code_version": str(result.get("agent_version", "")).split(" ", 1)[0],
            "permission_mode": "default",
            "entrypoint": "agent-eval-harness",
            "prompt": prompt[:500],
            "plugins_loaded": "agent-eval-harness",
            "analyzed_at": analyzed_at,
            "duration_ms": str(int(duration_ms * duration_ratio)),
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

if not rows:
    sys.exit(0)
document = metrics.build_autodl(rows[0])
document["rows"] = rows
with open(output_path, "w") as stream:
    json.dump(document, stream, indent=4)
PYEOF
    if [[ -s "${eval_extracted_file}" ]]; then
        extracted+=("${eval_extracted_file}")
    fi

    if [[ ${#extracted[@]} -gt 0 ]]; then
        python3 - "${output}" "${extracted[@]}" <<'PYEOF'
import json
import sys

output_path = sys.argv[1]
documents = []
for input_path in sys.argv[2:]:
    with open(input_path) as stream:
        documents.append(json.load(stream))
merged = documents[0]
merged["rows"] = [row for document in documents for row in document["rows"]]
with open(output_path, "w") as stream:
    json.dump(merged, stream, indent=4)
PYEOF
        row_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["rows"]))' "${output}")
        echo "Wrote ${row_count} Claude session row(s) to ${output}"
    else
        echo "No complete Claude sessions were available for metrics extraction."
    fi
    rm -rf "${temp_dir}"
}

extract_session_metrics

if [[ ! -f "${SHARED_DIR}/claude-session-available" ]]; then
    echo "No Claude session archive found. Skipping continue-session page."
    exit 0
fi

echo "Claude session archive detected. Generating continue-session page..."

# Build the Prow job URL
if [[ "${JOB_TYPE:-}" == "presubmit" ]]; then
    PROW_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
else
    PROW_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"
fi

cat > "${ARTIFACT_DIR}/continue-session-summary.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Continue This Claude Session Locally ✨</title>
<style>
  body { font-family: system-ui, sans-serif; background: #1a1a2e; color: #e0e0e0; max-width: 960px; margin: 0 auto; padding: 3rem 2rem; }
  h1 { text-align: center; }
  .subtitle { text-align: center; color: #888; margin-bottom: 2rem; }
  pre { background: #111; border: 1px solid #333; border-radius: 8px; padding: 1rem; color: #b39ddb; word-break: break-all; white-space: pre-wrap; cursor: pointer; position: relative; }
  pre:hover { border-color: #7c4dff; }
  ol { color: #aaa; margin: 2rem 0; padding-left: 1.5rem; }
  li { padding: 0.25rem 0; }
  a { color: #b39ddb; }
</style>
</head>
<body>
<h1>Continue This Claude Session Locally ✨</h1>
<p class="subtitle">Pick up right where the CI agent left off. Click below to copy.</p>
<pre id="cmd" onclick="navigator.clipboard.writeText(this.textContent).then(()=>{this.style.borderColor='#4caf50';setTimeout(()=>this.style.borderColor='',1500)})">/ci:continue-session ${PROW_URL}</pre>
<ol>
  <li>Install the <a href="https://github.com/openshift-eng/ai-helpers" target="_blank"><strong>ai-helpers</strong></a> marketplace</li>
  <li>Open Claude Code in your terminal</li>
  <li>Paste the command above and press Enter</li>
  <li>Claude will download the session and help you resume the conversation</li>
</ol>
<p>&nbsp;</p>
<p>&nbsp;</p>
<p>&nbsp;</p>
<p>&nbsp;</p>
</body>
</html>
HTMLEOF

echo "Continue-session page written to ${ARTIFACT_DIR}/continue-session-summary.html"
