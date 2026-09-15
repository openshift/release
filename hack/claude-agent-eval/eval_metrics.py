#!/usr/bin/env python3
"""AutoDL accounting ported from the legacy eval step, without a Bash bridge."""

import datetime
import importlib.util
import json
import pathlib
import sys
from collections import Counter

def main(args):  # pylint: disable=too-many-statements
    extractor_path, stream_path, result_path, output_path, build_id, run_id, prompt = args

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


    def add_orchestrator_rows():  # pylint: disable=too-many-statements
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
        with stream_file.open(encoding="utf-8", errors="replace") as stream:
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
        with result_file.open(encoding="utf-8") as stream:
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
            with output.open(encoding="utf-8") as stream:
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
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(document, stream, indent=4)
    temporary.replace(output)
    print(f"Wrote {len(rows)} eval metric row(s) to {output}")


if __name__ == "__main__":
    main(sys.argv[1:])
