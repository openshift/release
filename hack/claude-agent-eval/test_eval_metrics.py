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
            'SCHEMA = {"session_id": "string", "model": "string", "total_cost_usd": "float64", '
            '"num_turns": "int64", "duration_ms": "int64", "input_tokens": "int64", '
            '"output_tokens": "int64"}\n'
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
        self.assertEqual([skill["num_turns"], judge["num_turns"]], ["3", "1"])
        self.assertEqual(skill["session_id"], "eval-harness:build-42:one:skill")
        self.assertEqual(rows[6]["session_id"], "eval-harness:build-42:two:skill")

    def test_missing_partial_and_zero_turns_never_duplicate_the_run_total(self):
        self.stream.unlink()
        original = json.loads(self.result.read_text())
        scenarios = [
            ({}, {"skill": None, "judge": None}, 10),
            ({"per_model_turns": None}, {"skill": None, "judge": None}, 10),
            ({"per_model_turns": {}}, {"skill": None, "judge": None}, 10),
            ({"per_model_turns": []}, {"skill": None, "judge": None}, 10),
            ({"per_model_turns": {"skill": 3}}, {"skill": "3", "judge": None}, 7),
            ({"per_model_turns": {"skill": 0, "judge": None}}, {"skill": "0", "judge": None}, 10),
            ({"per_model_turns": {"skill": 0, "judge": 10}}, {"skill": "0", "judge": "10"}, 0),
        ]
        for fields, expected, remainder in scenarios:
            with self.subTest(fields=fields):
                self.output.unlink(missing_ok=True)
                document = {**original, "num_turns": 10}
                document.pop("per_model_turns")
                document.update(fields)
                self.result.write_text(json.dumps(document))
                process = self.run_metrics()
                self.assertEqual(process.returncode, 0, process.stderr)
                rows = json.loads(self.output.read_text())["rows"]
                models = {row["model"]: row.get("num_turns") for row in rows if row["model"]}
                self.assertEqual(models, expected)
                for row in rows:
                    if row["model"] and expected[row["model"]] is None:
                        self.assertNotIn("num_turns", row)
                self.assertEqual(sum(int(row["num_turns"]) for row in rows if "num_turns" in row), 10)
                self.assertAlmostEqual(sum(float(row["total_cost_usd"]) for row in rows), 0.4)
                self.assertEqual(sum(int(row["input_tokens"]) for row in rows), 16)
                self.assertEqual(sum(int(row["output_tokens"]) for row in rows), 20)
                unassigned = [row for row in rows if not row["model"]]
                self.assertEqual(len(unassigned), int(bool(remainder)))
                if remainder:
                    self.assertEqual(unassigned[0]["num_turns"], str(remainder))
                    self.assertEqual(unassigned[0]["duration_ms"], "0")
                    self.assertEqual(unassigned[0]["terminal_reason"], "unattributed_turns")
                    # Existing per-model duration allocation truncates milliseconds.
                    self.assertAlmostEqual(sum(int(row["duration_ms"]) for row in rows), 2000, delta=2)
                    self.assertIn("turns unavailable", process.stdout)

    def test_unknown_turns_without_run_total_are_not_invented(self):
        self.stream.unlink()
        original = json.loads(self.result.read_text())
        for fields, counts in (({}, {}), ({"num_turns": None}, None),
                               ({}, {"skill": 0, "judge": None})):
            with self.subTest(fields=fields, counts=counts):
                self.output.unlink(missing_ok=True)
                document = {**original, "per_model_turns": counts, **fields}
                self.result.write_text(json.dumps(document))
                process = self.run_metrics()
                self.assertEqual(process.returncode, 0, process.stderr)
                rows = json.loads(self.output.read_text())["rows"]
                self.assertEqual(len(rows), 2)
                models = {row["model"]: row for row in rows}
                if counts:
                    self.assertEqual(models["skill"]["num_turns"], "0")
                else:
                    self.assertNotIn("num_turns", models["skill"])
                self.assertNotIn("num_turns", models["judge"])

    def test_zero_total_is_preserved_without_claiming_per_model_zero(self):
        self.stream.unlink()
        document = json.loads(self.result.read_text())
        document.update(num_turns=0, per_model_turns=None)
        self.result.write_text(json.dumps(document))
        self.assertEqual(self.run_metrics().returncode, 0)
        rows = json.loads(self.output.read_text())["rows"]
        for row in rows:
            if row["model"]:
                self.assertNotIn("num_turns", row)
        aggregate, = [row for row in rows if not row["model"]]
        self.assertEqual(aggregate["num_turns"], "0")

    def test_known_zero_without_token_usage_is_not_dropped(self):
        self.stream.unlink()
        self.result.write_text(json.dumps({"model": "skill", "per_model_turns": {"skill": 0}}))
        process = self.run_metrics()
        self.assertEqual(process.returncode, 0, process.stderr)
        row, = json.loads(self.output.read_text())["rows"]
        self.assertEqual(row["model"], "skill")
        self.assertEqual(row["num_turns"], "0")

    def test_append_preserves_unknown_counts_and_existing_schema(self):
        self.stream.unlink()
        document = json.loads(self.result.read_text())
        document.update(num_turns=10, per_model_turns=None)
        self.result.write_text(json.dumps(document))
        self.assertEqual(self.run_metrics("one").returncode, 0)
        first = json.loads(self.output.read_text())
        self.assertEqual(first["schema"]["num_turns"], "int64")
        document.update(per_model_turns={"skill": 3, "judge": 7})
        self.result.write_text(json.dumps(document))
        self.assertEqual(self.run_metrics("two").returncode, 0)
        second = json.loads(self.output.read_text())
        self.assertEqual(second["schema"], first["schema"])
        self.assertEqual(second["rows"][:3], first["rows"])
        for row in second["rows"][:2]:
            self.assertNotIn("num_turns", row)
        self.assertEqual(sum(int(row["num_turns"]) for row in second["rows"] if "num_turns" in row), 20)

    def test_known_counts_survive_missing_usage_and_missing_or_smaller_total(self):
        self.stream.unlink()
        original = json.loads(self.result.read_text())
        for total in (None, 0, 2):
            with self.subTest(total=total):
                self.output.unlink(missing_ok=True)
                self.result.write_text(json.dumps({**original, "num_turns": total,
                    "per_model_turns": {"skill": 3, "judge": 0, "helper": 2}}))
                process = self.run_metrics()
                self.assertEqual(process.returncode, 0, process.stderr)
                rows = json.loads(self.output.read_text())["rows"]
                self.assertEqual({row["model"]: int(row["num_turns"]) for row in rows},
                                 {"skill": 3, "judge": 0, "helper": 2})

    def test_run_total_without_usage_is_not_dropped(self):
        self.stream.unlink()
        self.result.write_text(json.dumps({"num_turns": 10, "exit_code": 0}))
        process = self.run_metrics()
        self.assertEqual(process.returncode, 0, process.stderr)
        row, = json.loads(self.output.read_text())["rows"]
        self.assertEqual(row["num_turns"], "10")
        self.assertEqual(row["model"], "")
        self.assertEqual(row["total_cost_usd"], "0")

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
        self.assertNotIn("num_turns", row)

    def test_incompatible_existing_artifact_is_not_overwritten(self):
        original = '{"schema": {"unexpected": "string"}, "rows": []}'
        self.output.write_text(original)
        self.assertNotEqual(self.run_metrics().returncode, 0)
        self.assertEqual(self.output.read_text(), original)


if __name__ == "__main__":
    unittest.main()
