#!/usr/bin/env python3
"""Focused regressions for TRT OTEL accounting and eval lifecycle glue."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
TRT = ROOT / "ci-operator/step-registry/openshift/agentic/trt"
INIT = TRT / "init-model/openshift-agentic-trt-init-model-commands.sh"
SOLVE = TRT / "eval/solve/openshift-agentic-trt-eval-solve-commands.sh"
JUDGE = TRT / "eval/judge/openshift-agentic-trt-eval-judge-commands.sh"
RESPOND = TRT / "review-responder-eval/respond/openshift-agentic-trt-review-responder-eval-respond-commands.sh"
JIRA_SOLVER = TRT / "jira-solver/openshift-agentic-trt-jira-solver-commands.sh"
REVIEW_RESPONDER = TRT / "review-responder/openshift-agentic-trt-review-responder-commands.sh"


def any_value(value):
    """Encode a scalar as an OTLP AnyValue; lists intentionally stay malformed."""
    if isinstance(value, (str, list)):
        return {"stringValue": value}
    return {"intValue": value}


def attributes(values):
    """Build OTLP attributes from a mapping."""
    return [{"key": key, "value": any_value(value)} for key, value in values.items()]


def cost_metric(name, amount, start, timestamp, model, broken=None):
    """Build one cumulative cost point."""
    attrs = {"model": model}
    if broken is not None:
        attrs["broken"] = broken
    value_key = "asDouble" if isinstance(amount, float) else "asInt"
    return {"name": name, "sum": {"aggregationTemporality": 2, "dataPoints": [{
        value_key: amount,
        "startTimeUnixNano": start,
        "timeUnixNano": timestamp,
        "attributes": attributes(attrs),
    }]}}


def resource(producer, metrics, scope_name="synthetic-scope"):
    """Wrap metrics with stable resource and instrumentation-scope identity."""
    return {
        "resource": {"attributes": attributes({"service.name": producer})},
        "schemaUrl": "resource-schema",
        "scopeMetrics": [{
            "scope": {"name": scope_name, "version": "1"},
            "schemaUrl": "scope-schema",
            "metrics": metrics,
        }],
    }


def response(model, input_count, output, cached=0, created=0):
    """Build one sanitized Codex response.completed log record."""
    return {"attributes": attributes({
        "event.name": "codex.sse_event",
        "event.kind": "response.completed",
        "model": model,
        "input_token_count": input_count,
        "output_token_count": output,
        "cached_token_count": cached,
        "cache_write_token_count": created,
        "app.version": "synthetic-version",
        "conversation.id": "synthetic-session",
    })}


def heredoc(script, function_name):
    """Return the first Python heredoc inside a named shell function."""
    text = script.read_text()
    start = text.index(f"{function_name}() {{")
    start = text.index("<<'PY'\n", start) + len("<<'PY'\n")
    return text[start:text.index("\nPY\n", start)]


def jq_program(script, marker):
    """Return the jq program passed after a unique argument marker."""
    text = script.read_text()
    start = text.index(marker) + len(marker)
    return text[start:text.index("\n        ' \"${METRICS_TMP}\"", start)]


class TrtMetricsTests(unittest.TestCase):
    """Exercise generated helpers and the exact eval consumer programs."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shared = self.root / "shared"
        shared.mkdir()
        env = {**os.environ, "SHARED_DIR": str(shared),
               "ARTIFACT_DIR": str(self.root), "EVAL_MODE": "true"}
        subprocess.run(["bash", str(INIT)], env=env, check=True,
                       stdout=subprocess.DEVNULL)
        self.helper = shared / "trt-telemetry.sh"

    def run_usage(self, records):
        """Run the generated OTEL parser over JSON values or raw lines."""
        source = self.root / "otel.jsonl"
        source.write_text("\n".join(
            item if isinstance(item, str) else json.dumps(item) for item in records
        ) + "\n")
        script = (
            'source "$1"; status=0; otel_usage "$2" || status=$?; '
            'rm -f "$SESSION_PROMPT_FILE"; exit "$status"'
        )
        result = subprocess.run(["bash", "-c", script, "_", str(self.helper), str(source)],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout), result.stderr

    def fixture_usage(self):
        """Return producer-aware multi-model usage with malformed neighbors."""
        metrics = {"path": "/v1/metrics", "payload": {"resourceMetrics": [
            resource("producer-a", [
                cost_metric("codex.cost.usage", 1, "same", "1", "gpt-primary"),
                cost_metric("agentic_ci.codex.cost.usage", 2, "same", "2", "gpt-primary"),
                cost_metric("agentic_ci.codex.cost.usage", 4, "resume", "4", "gpt-primary"),
                cost_metric("agentic_ci.codex.cost.usage", 1.25, "helper", "1", "gpt-helper"),
                cost_metric("agentic_ci.codex.cost.usage", 10**400, "bad", "1", "overflow"),
                cost_metric("agentic_ci.codex.cost.usage", "NaN", "bad", "2", "nan"),
                cost_metric("agentic_ci.codex.cost.usage", 8, "bad-list", "1", "broken-list", []),
                cost_metric("agentic_ci.codex.cost.usage", 8, "bad-dict", "1", "broken-dict", {}),
            ]),
            resource("producer-b", [
                cost_metric("agentic_ci.codex.cost.usage", 3, "same", "3", "gpt-primary"),
            ]),
            resource("producer-a", [
                cost_metric("agentic_ci.codex.cost.usage", 0.5, "same", "3", "gpt-primary"),
            ], scope_name="synthetic-scope-b"),
        ]}}
        logs = {"path": "/v1/logs", "payload": {"resourceLogs": [{"scopeLogs": [{
            "logRecords": [
                response("gpt-primary", 50, 4, cached=2, created=1),
                response("gpt-helper", 5, 2, cached=1),
                response("gpt-primary", "not-a-count", 999),
            ],
        }]}]}}
        return self.run_usage(["{malformed", None, [], metrics, logs])

    def test_otel_usage_handles_aliases_producers_malformed_input_and_models(self):
        usage, stderr = self.fixture_usage()
        models = usage["codex"]["models"]
        self.assertEqual(models["gpt-primary"]["cost"], 9.5)
        self.assertEqual(models["gpt-helper"]["cost"], 1.25)
        self.assertEqual(models["gpt-primary"]["turns"], 1)
        self.assertEqual(models["gpt-primary"]["input"], 47)
        self.assertEqual(models["gpt-helper"]["turns"], 1)
        self.assertNotIn("overflow", models)
        self.assertNotIn("nan", models)
        self.assertNotIn("broken-list", models)
        self.assertNotIn("broken-dict", models)
        self.assertIn("skipped 1 Codex response events", stderr)

    def run_jq(self, program, document, usage, exit_code=0):
        """Execute an exact checked-in eval jq program."""
        args = ["jq", "--arg", "configured", "gpt-primary",
                "--argjson", "otel_usage", json.dumps(usage)]
        if "$exit_code" in program:
            args += ["--argjson", "exit_code", str(exit_code)]
        args.append(program)
        result = subprocess.run(args, input=json.dumps(document), capture_output=True,
                                text=True, check=True)
        return json.loads(result.stdout)

    def test_solve_and_review_consumers_use_session_totals_and_fallback(self):
        usage, _stderr = self.fixture_usage()
        row = {
            "model": "gpt-primary", "claude_code_version": "synthetic-version",
            "duration_ms": "12000", "is_error": "0", "total_cost_usd": "10.750000",
            "num_turns": "2", "input_tokens": "51", "output_tokens": "6",
            "cache_read_input_tokens": "3", "cache_creation_input_tokens": "1",
        }
        solve = jq_program(SOLVE, '--argjson exit_code "${CASE_EXIT_CODE}" \'\n')
        review = jq_program(RESPOND, '--argjson otel_usage "${OTEL_USAGE}" \'\n')
        for program in (solve, review):
            with self.subTest(consumer="solve" if program == solve else "review"):
                result = self.run_jq(program, {"rows": [row]}, usage)
                self.assertEqual(result["cost_usd"], 10.75)
                self.assertEqual(result["num_turns"], 2)
                self.assertEqual(result["token_usage"], {
                    "input": 51, "output": 6, "cache_read": 3, "cache_create": 1})
                fallback = self.run_jq(program, {"rows": []}, usage)
                self.assertEqual(fallback["cost_usd"], 10.75)
                self.assertEqual(fallback["num_turns"], 2)

        partial = json.loads(json.dumps(usage))
        partial["codex"]["models"]["gpt-helper"].pop("cost")
        result = self.run_jq(solve, {"rows": [row]}, partial, exit_code=23)
        self.assertFalse(result["cost_observed"])
        self.assertIsNone(result["cost_usd"])
        self.assertEqual(result["observed_cost_usd"], 10.75)
        self.assertEqual(result["exit_code"], 23)

        zero = json.loads(json.dumps(usage))
        for model_usage in zero["codex"]["models"].values():
            model_usage["cost"] = 0
        zero_row = {**row, "total_cost_usd": "0.000000"}
        result = self.run_jq(solve, {"rows": [zero_row]}, zero)
        self.assertTrue(result["cost_observed"])
        self.assertEqual(result["cost_usd"], 0)

        missing = json.loads(json.dumps(usage))
        missing["codex"]["cost_from_metric"] = False
        for model_usage in missing["codex"]["models"].values():
            model_usage.pop("cost")
        result = self.run_jq(solve, {"rows": [zero_row]}, missing)
        self.assertFalse(result["cost_observed"])
        self.assertIsNone(result["cost_usd"])

    def test_malformed_line_keeps_valid_two_dollar_fallback(self):
        """Both real eval jq consumers retain valid usage after a bad JSONL line."""
        metrics = {"path": "/v1/metrics", "payload": {"resourceMetrics": [
            resource("producer", [
                cost_metric("agentic_ci.codex.cost.usage", 2, "start", "1", "gpt-primary"),
            ]),
        ]}}
        logs = {"path": "/v1/logs", "payload": {"resourceLogs": [{"scopeLogs": [{
            "logRecords": [response("gpt-primary", 3, 4)],
        }]}]}}
        usage, _stderr = self.run_usage(["{malformed", metrics, logs])
        solve = jq_program(SOLVE, '--argjson exit_code "${CASE_EXIT_CODE}" \'\n')
        review = jq_program(RESPOND, '--argjson otel_usage "${OTEL_USAGE}" \'\n')
        for program in (solve, review):
            result = self.run_jq(program, {"rows": []}, usage)
            self.assertEqual(result["cost_usd"], 2)
            self.assertEqual(result["num_turns"], 1)
            self.assertIsNone(result["duration_s"])

    def test_two_case_aggregation_keeps_per_case_costs(self):
        program = heredoc(SOLVE, "aggregate_eval_run_result")
        per_case = self.root / "per-case.json"
        output = self.root / "run-result.json"
        case = {
            "model": "gpt-primary", "agent": "codex", "agent_version": "synthetic",
            "duration_s": 1, "cost_observed": True, "cost_usd": 1.25,
            "observed_cost_usd": 1.25, "num_turns": 1, "exit_code": 0,
            "token_usage": {"input": 1, "output": 2, "cache_read": 3, "cache_create": 4},
            "per_model_usage": {}, "per_model_turns": {},
        }
        per_case.write_text(json.dumps({"case-a": case, "case-b": case}))
        subprocess.run([sys.executable, "-", str(per_case), str(output),
                        "gpt-primary", "1"], input=program, text=True, check=True)
        result = json.loads(output.read_text())
        self.assertEqual(result["cost_usd"], 2.5)
        self.assertEqual([result["per_case"][name]["cost_usd"]
                          for name in ("case-a", "case-b")], [1.25, 1.25])
        incomplete = json.loads(per_case.read_text())
        incomplete["case-b"].update(cost_observed=False, cost_usd=None)
        per_case.write_text(json.dumps(incomplete))
        subprocess.run([sys.executable, "-", str(per_case), str(output),
                        "gpt-primary", "1"], input=program, text=True, check=True)
        result = json.loads(output.read_text())
        self.assertIsNone(result["cost_usd"])
        self.assertEqual(result["observed_cost_usd"], 2.5)
        self.assertEqual(result["cost_unobserved_cases"], ["case-b"])

    def test_extractor_guard_and_prompt_cleanup_preserve_exit_status(self):
        old = self.root / "old-extractor.py"
        old.write_text("old extractor\n")
        current = self.root / "current-extractor.py"
        current.write_text("--prompt-file agentic_ci.codex.cost.usage _producer_key\n")
        for extractor, expected in ((old, 1), (current, 0)):
            command = ('source "$1"; EXTRACT_METRICS="$2"; '
                       'require_session_metrics_extractor; rc=$?; '
                       'rm -f "$SESSION_PROMPT_FILE"; exit "$rc"')
            result = subprocess.run(["bash", "-c", command, "_", str(self.helper),
                                     str(extractor)], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected)

        blocks = [
            (JIRA_SOLVER, "solver_cleanup() {", "load_github_tokens"),
            (REVIEW_RESPONDER, "review_prompt_cleanup() {", "# Prior steps"),
        ]
        for path, start_marker, end_marker in blocks:
            text = path.read_text()
            block = text[text.index(start_marker):text.index(end_marker)]
            for action, expected in (("exit 0", 0), ("exit 23", 23),
                                     ("kill -TERM $$", 143), ("kill -INT $$", 130)):
                with self.subTest(path=path.name, action=action):
                    prompt = self.root / f"prompt-{path.stem}-{expected}"
                    prompt.write_text("sanitized")
                    prelude = (
                        'set -e; SESSION_PROMPT_FILE="$1"; copy_artifacts(){ :; }; '
                        'require_session_metrics_extractor(){ :; }; '
                    )
                    result = subprocess.run(["bash", "-c", prelude + block + action,
                                             "_", str(prompt)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertFalse(prompt.exists())

            prompt = self.root / f"prompt-setup-{path.stem}"
            prompt.write_text("sanitized")
            prelude = (
                'set -e; SESSION_PROMPT_FILE="$1"; copy_artifacts(){ :; }; '
                'require_session_metrics_extractor(){ return 17; }; '
            )
            setup_failure = "" if "require_session_metrics_extractor" in block else "false"
            expected_setup_status = 17 if not setup_failure else 1
            result = subprocess.run(["bash", "-c", prelude + block + setup_failure,
                                     "_", str(prompt)], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected_setup_status)
            self.assertFalse(prompt.exists())

            prompt = self.root / f"prompt-fail-{path.stem}"
            prompt.write_text("sanitized")
            prelude = ('set -e; SESSION_PROMPT_FILE="$1"; copy_artifacts(){ :; }; '
                       'require_session_metrics_extractor(){ :; }; rm(){ return 1; }; ')
            result = subprocess.run(["bash", "-c", prelude + block + "exit 23",
                                     "_", str(prompt)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 23)
            self.assertIn("failed to remove private prompt temporary file", result.stderr)

    def test_judge_verifier_rejects_empty_and_reports_counts(self):
        program = heredoc(JUDGE, "verify_eval_costs")
        result_path = self.root / "run-result.json"
        cases_path = self.root / "cases"
        result_path.write_text(json.dumps({
            "execution_mode": "case", "num_cases": 1, "cost_observed": True,
            "cost_usd": 1.25, "per_case": {
                "case-a": {"cost_observed": True, "cost_usd": 1.25},
            },
        }))
        cases_path.write_text("")
        process = subprocess.run([sys.executable, "-", str(result_path), str(cases_path)],
                                 input=program, capture_output=True, text=True)
        self.assertEqual(process.returncode, 1)
        self.assertIn("eval case list is empty", process.stderr)
        self.assertIn("expected_count=0 actual_count=1", process.stderr)

    def test_solve_rejects_empty_case_file_before_setup(self):
        shared = self.root / "empty-cases-shared"
        shared.mkdir()
        (shared / "eval-cases").write_text("\n")
        (shared / "github-app-auth.sh").write_text(
            "load_github_tokens(){ :; }\nconfigure_github_git_credentials(){ :; }\n")
        env = {**os.environ, "SHARED_DIR": str(shared),
               "ARTIFACT_DIR": str(self.root / "artifacts"),
               "UPSTREAM_REPO": "synthetic/repo", "FORK_REPO": "synthetic/fork"}
        process = subprocess.run(["bash", str(SOLVE)], env=env,
                                 capture_output=True, text=True)
        self.assertEqual(process.returncode, 1)
        self.assertIn("eval-cases contains no cases", process.stderr)
        self.assertNotIn("Cloning into", process.stderr)

    def test_review_requested_structure_and_neutral_wording(self):
        solve = SOLVE.read_text()
        copy_start = solve.index("copy_artifacts() {")
        copy_end = solve.index("\n}\n", copy_start)
        self.assertNotIn("METRICS_TEMP_FILES", solve[copy_start:copy_end])
        cleanup_start = solve.index("cleanup_eval_solve() {")
        cleanup_end = solve.index("\n}\n", cleanup_start)
        self.assertIn("METRICS_TEMP_FILES", solve[cleanup_start:cleanup_end])

        judge = JUDGE.read_text()
        self.assertLess(judge.index('rm -f "${RUN_DIR}/run_result.json"'),
                        judge.index('cp "${SHARED_DIR}/eval-solve-run-result.json"'))
        self.assertLess(judge.index('cp "${SHARED_DIR}/eval-solve-run-result.json"'),
                        judge.index("prow-agent-eval judge"))
        self.assertLess(judge.index("prow-agent-eval judge"),
                        judge.index("verify_eval_costs \"${RUN_DIR}"))
        self.assertLess(judge.index("if [[ ${JUDGE_STATUS} -ne 0 ]]"),
                        judge.index('exit "${COST_STATUS}"'))

        validator = (ROOT / "hack/validate-ai-metrics.sh").read_text()
        self.assertIn("billable AI agent", validator)
        self.assertIn("Claude or Codex agent", validator)
        self.assertNotIn("billable Claude agent", validator)

        init = INIT.read_text()
        self.assertIn('Failed to propagate session identity to ${metadata_file##*/}', init)


if __name__ == "__main__":
    unittest.main()
