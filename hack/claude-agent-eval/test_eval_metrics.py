#!/usr/bin/env python3
"""Verify multi-model accounting and appending results across sequential evals."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.extractor = self.root / "extract_metrics.py"
        self.extractor.write_text(
            'SCHEMA = {"session_id": "string", "model": "string", "total_cost_usd": "number"}\n'
            'def build_autodl(row): return {"schema": SCHEMA, "rows": [row]}\n')
        self.output = self.root / "metrics.json"
        self.stream = self.root / "stream.jsonl"
        records = [
            {"type": "system", "subtype": "init", "session_id": "orchestrator", "model": "outer"},
            {"type": "assistant", "message": {"content": [
                {"type": "tool_use", "id": "tool-1", "name": "Skill", "input": {"skill": "eval-run"}},
                {"type": "tool_use", "id": "tool-1", "name": "Skill", "input": {"skill": "eval-run"}},
            ]}},
            {"type": "result", "num_turns": 4, "duration_ms": 1000, "modelUsage": {
                "outer": {"costUSD": 0.75, "inputTokens": 10, "outputTokens": 20},
                "helper": {"costUSD": 0.25, "inputTokens": 5, "outputTokens": 5}}},
        ]
        self.stream.write_text("\n".join(json.dumps(r) for r in records))
        self.result = self.root / "run_result.json"
        self.result.write_text(json.dumps({
            "exit_code": 0, "duration_s": 2, "per_model_turns": {"skill": 3, "judge": 1},
            "per_model_usage": {"skill": {"cost_usd": 0.3, "input": 12, "output": 15},
                                "judge": {"cost_usd": 0.1, "input": 4, "output": 5}},
        }))

    def run_metrics(self, run_id="one"):
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("eval_metrics.py")),
             str(self.extractor), str(self.stream), str(self.result), str(self.output),
             "build-42", run_id, "/eval-run"], capture_output=True, text=True, check=False)

    def test_multiple_models_append_without_overwriting_previous_evals(self):
        for run_id in ("one", "two"):
            result = self.run_metrics(run_id)
            self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(self.output.read_text())["rows"]
        self.assertEqual(len(rows), 8)
        self.assertAlmostEqual(sum(float(row["total_cost_usd"]) for row in rows), 2.8)
        outer, helper, skill, judge = rows[:4]
        self.assertEqual([r["model"] for r in rows[:4]], ["outer", "helper", "skill", "judge"])
        self.assertEqual([outer["duration_ms"], helper["duration_ms"]], ["750", "250"])
        self.assertEqual([skill["duration_ms"], judge["duration_ms"]], ["1500", "500"])
        self.assertEqual([outer["total_tool_calls"], helper["total_tool_calls"]], ["1", "0"])
        self.assertEqual([outer["num_turns"], helper["num_turns"]], ["4", "0"])
        self.assertEqual(skill["session_id"], "eval-harness:build-42:one:skill")
        self.assertEqual(rows[6]["session_id"], "eval-harness:build-42:two:skill")

    def test_missing_harness_result_still_accounts_for_orchestrator(self):
        self.result.unlink()
        result = self.run_metrics()
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = json.loads(self.output.read_text())["rows"]
        self.assertEqual(len(rows), 2)
        self.assertAlmostEqual(sum(float(row["total_cost_usd"]) for row in rows), 1.0)

    def test_failure_and_single_model_fallback(self):
        self.stream.unlink()
        self.result.write_text(json.dumps({
            "exit_code": 1, "model": "skill", "cost_usd": 0.2,
            "token_usage": {"input": 10, "output": 3}, "duration_s": 1,
        }))
        result = self.run_metrics()
        self.assertEqual(result.returncode, 0, result.stderr)
        row, = json.loads(self.output.read_text())["rows"]
        self.assertEqual(row["is_error"], "1")
        self.assertEqual(row["terminal_reason"], "eval_failed")
        self.assertEqual(row["total_cost_usd"], "0.200000")

    def test_incompatible_existing_artifact_is_not_overwritten(self):
        original = '{"schema": {"unexpected": "string"}, "rows": []}'
        self.output.write_text(original)
        self.assertNotEqual(self.run_metrics().returncode, 0)
        self.assertEqual(self.output.read_text(), original)


if __name__ == "__main__":
    unittest.main()
