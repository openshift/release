"""Fault injection for eval finalization, reporting, and control flow."""

import contextlib
import json
from unittest import mock

import test_manifest_runner as support

runner = support.runner


class LifecycleTests(support.Fixture):
    def assert_unexpected_failure_continues(self, action, error):
        other = self.make_entry("evals/other.yaml")
        self.write_manifest([self.entry, other])
        self.change_skill()
        self.artifacts.mkdir()
        plans = runner.manifest_plans(self.repo, self.env)
        original = getattr(runner, action)
        injected = False

        def fail_once(*args):
            nonlocal injected
            if not injected:
                injected = True
                raise error
            return original(*args)

        with mock.patch.object(runner, action, side_effect=fail_once):
            self.assertEqual(runner.run_evals(self.repo, plans, self.artifacts, self.env), 1)
        self.assertEqual(len(self.claude_calls()), 2)
        self.assertEqual(self.junit().attrib["tests"], "2")
        self.assertEqual(self.junit().attrib["failures"], "1")
        summary = json.loads((self.artifacts / "evals-summary.json").read_text())
        self.assertEqual([e["status"] for e in summary["evals"]], ["failed", "passed"])
        self.assertIn(type(error).__name__, summary["evals"][0]["failure"])
        self.assertIn(type(error).__name__, self.index())
        self.assertTrue((self.eval_artifacts() / "claude-eval.log").is_file())
        self.assertTrue((self.eval_artifacts(other["config"]) / "eval-run.tar").is_file())

    def test_unexpected_verifier_failure_continues(self):
        self.assert_unexpected_failure_continues("verify_result", RuntimeError())

    def test_unexpected_collector_failure_continues(self):
        self.assert_unexpected_failure_continues("collect_result", RuntimeError("collector failed"))

    def test_unexpected_archive_failure_continues(self):
        self.assert_unexpected_failure_continues("archive", RuntimeError("archive failed"))

    def test_runtime_threshold_failure_continues(self):
        with self.assertRaises(runner.EvalError) as caught:
            runner.verify_result(self.repo, {"thresholds": None})
        self.assert_unexpected_failure_continues("verify_result", caught.exception)

    def test_control_flow_does_not_continue_or_report_pass(self):
        for action, error in (("verify_result", SystemExit(2)),
                              ("verify_result", KeyboardInterrupt()),
                              ("collect_result", runner.Interrupted("signal 15"))):
            with self.subTest(action=action, error=type(error).__name__):
                fixture = support.Fixture()
                fixture.setUp()
                try:
                    other = fixture.make_entry("evals/other.yaml")
                    fixture.write_manifest([fixture.entry, other])
                    fixture.change_skill()
                    fixture.artifacts.mkdir()
                    plans = runner.manifest_plans(fixture.repo, fixture.env)
                    with mock.patch.object(runner, action, side_effect=error):
                        if isinstance(error, runner.Interrupted):
                            self.assertEqual(runner.run_evals(fixture.repo, plans, fixture.artifacts, fixture.env), 1)
                        else:
                            with self.assertRaises(type(error)):
                                runner.run_evals(fixture.repo, plans, fixture.artifacts, fixture.env)
                    self.assertEqual(len(fixture.claude_calls()), 1)
                    summary = json.loads((fixture.artifacts / "evals-summary.json").read_text())
                    self.assertEqual([e["status"] for e in summary["evals"]], ["failed", "not_run"])
                    self.assertGreater(int(fixture.junit().attrib["failures"]), 0)
                finally:
                    fixture.doCleanups()

    def test_unexpected_metrics_failure_is_nonfatal(self):
        self.change_skill()
        self.artifacts.mkdir()
        plans = runner.manifest_plans(self.repo, self.env)
        original = runner.command

        def fail_metrics(args, *rest, **kwargs):
            if "eval_metrics.py" in str(args):
                raise RuntimeError("metrics failed")
            return original(args, *rest, **kwargs)

        with mock.patch.object(runner, "command", side_effect=fail_metrics):
            self.assertEqual(runner.run_evals(self.repo, plans, self.artifacts, self.env), 0)
        self.assertEqual(self.junit().attrib["failures"], "0")

    def test_unexpected_report_failure_attempts_other_reports(self):
        self.artifacts.mkdir()
        for failing in ("write_summary", "write_index", "write_junit"):
            with self.subTest(writer=failing), contextlib.ExitStack() as stack:
                writers = {}
                for name in ("write_summary", "write_index", "write_junit"):
                    writers[name] = stack.enter_context(mock.patch.object(
                        runner, name, side_effect=RuntimeError("writer failed") if name == failing else None,
                        wraps=None if name == failing else getattr(runner, name)))
                results, errors = [], []
                runner.write_reports(self.artifacts, results, [], errors)
                self.assertTrue(all(writer.called for writer in writers.values()))
                self.assertTrue(errors)
                self.assertTrue(results[0][2])
