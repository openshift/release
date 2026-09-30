"""Fault injection for eval finalization, reporting, and control flow."""

import contextlib
import json
import sys
from unittest import mock

import yaml

try:
    from . import test_manifest_runner as support
except ImportError:
    import test_manifest_runner as support

runner = support.runner
config_bridge = support.config_bridge
load_sibling = support.load_sibling


class LifecycleTests(support.Fixture):
    def test_interruption_during_harness_preparation_finishes_reports(self):
        self.change_skill()
        entries, files = runner.select_manifest_entries(self.repo, self.env)
        with mock.patch.object(runner, "command",
                               side_effect=runner.Interrupted("interrupted by signal 15")):
            self.assertEqual(runner.run_evals(self.repo, entries, files,
                                              self.artifacts, self.env), 1)
        self.assertEqual(self.claude_calls(), [])
        self.assertIn("interrupted by signal 15",
                      (self.artifacts / "evals-summary.json").read_text())
        self.assertGreater(int(self.junit().attrib["failures"]), 0)
        self.assertTrue((self.artifacts / "runner/harness-install.log").is_file())
        summary = json.loads((self.artifacts / "evals-summary.json").read_text())
        self.assertEqual([entry["status"] for entry in summary["evals"]], ["not_run"])

    def test_initial_report_failure_during_preparation_is_non_success(self):
        self.change_skill()
        entries, files = runner.select_manifest_entries(self.repo, self.env)
        original = runner.write_summary
        failed = False

        def fail_once(*args):
            nonlocal failed
            if not failed:
                failed = True
                raise OSError("initial summary unavailable")
            return original(*args)

        with mock.patch.object(runner, "write_summary", side_effect=fail_once):
            self.assertEqual(runner.run_evals(self.repo, entries, files,
                                              self.artifacts, self.env), 1)
        self.assertEqual(len(self.claude_calls()), 1)
        self.assertIn("initial summary unavailable",
                      (self.artifacts / "evals-summary.json").read_text())
        self.assertGreater(int(self.junit().attrib["failures"]), 0)

    def assert_unexpected_failure_continues(self, action, error):
        other = self.make_entry("evals/other.yaml")
        self.write_manifest([self.entry, other])
        self.change_skill()
        self.artifacts.mkdir()
        entries, files = runner.select_manifest_entries(self.repo, self.env)
        original = getattr(runner, action)
        injected = False

        def fail_once(*args):
            nonlocal injected
            if not injected:
                injected = True
                raise error
            return original(*args)

        with mock.patch.object(runner, action, side_effect=fail_once):
            self.assertEqual(runner.run_evals(self.repo, entries, files, self.artifacts, self.env), 1)
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
                    entries, files = runner.select_manifest_entries(fixture.repo, fixture.env)
                    with mock.patch.object(runner, action, side_effect=error):
                        if isinstance(error, runner.Interrupted):
                            self.assertEqual(runner.run_evals(fixture.repo, entries, files,
                                                              fixture.artifacts, fixture.env), 1)
                        else:
                            with self.assertRaises(type(error)):
                                runner.run_evals(fixture.repo, entries, files,
                                                 fixture.artifacts, fixture.env)
                    self.assertEqual(len(fixture.claude_calls()), 1)
                    summary = json.loads((fixture.artifacts / "evals-summary.json").read_text())
                    self.assertEqual([e["status"] for e in summary["evals"]], ["failed", "not_run"])
                    self.assertGreater(int(fixture.junit().attrib["failures"]), 0)
                finally:
                    fixture.doCleanups()

    def test_unexpected_metrics_failure_is_nonfatal(self):
        self.change_skill()
        self.artifacts.mkdir()
        entries, files = runner.select_manifest_entries(self.repo, self.env)
        original = runner.command

        def fail_metrics(args, *rest, **kwargs):
            if "eval_metrics.py" in str(args):
                raise RuntimeError("metrics failed")
            return original(args, *rest, **kwargs)

        with mock.patch.object(runner, "command", side_effect=fail_metrics):
            self.assertEqual(runner.run_evals(self.repo, entries, files, self.artifacts, self.env), 0)
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


class HarnessPreparationTests(support.Fixture):
    def test_failed_harness_fetch_has_junit(self):
        self.change_skill()
        self.assertNotEqual(self.run_step(FETCH_EXIT="1").returncode, 0)
        self.assertEqual(self.claude_calls(), [])
        self.assertEqual(self.junit().attrib["failures"], "1")
        self.assertEqual(json.loads((self.artifacts / "evals-summary.json").read_text())["evals"][0]["status"], "not_run")
        self.assertIn("runner/harness-install.log", self.index())
        self.assertIn("fake harness fetch failed",
                      (self.artifacts / "runner/harness-install.log").read_text())

    def test_failed_checkout_or_wrong_harness_revision_has_junit(self):
        self.change_skill()
        for overrides, expected in (({"CHECKOUT_EXIT": "1"}, "fake harness checkout failed"),
                                    ({"PINNED_REVISION": "wrong"}, "revision mismatch")):
            with self.subTest(overrides=overrides):
                self.calls_path.unlink(missing_ok=True)
                result = self.run_step(**overrides)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.claude_calls(), [])
                self.assertEqual(self.junit().attrib["failures"], "1")
                self.assertIn(expected, (self.artifacts / "runner/harness-install.log").read_text())


class ConfigValidationTests(support.Fixture):
    def test_invalid_thresholds_fail_before_any_calls(self):
        other = self.make_entry("evals/other.yaml")
        self.write_manifest([self.entry, other])
        self.change_skill()
        config = yaml.safe_load((self.repo / self.entry["config"]).read_text())
        for value in (None, [], "quality", False, {"quality": None}, {"": {}}):
            with self.subTest(thresholds=value):
                self.put(self.entry["config"], yaml.safe_dump({**config, "thresholds": value}))
                result = self.run_step()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.claude_calls(), [])
                self.assertEqual(self.junit().attrib["failures"], "1")
                summary = json.loads((self.artifacts / "evals-summary.json").read_text())
                self.assertEqual(summary["status"], "failed")
                self.assertEqual(summary["counts"]["passed"], 0)
                self.assertIn("thresholds must",
                              (self.eval_artifacts() / "config-resolution.log").read_text())

    def test_later_invalid_config_prevents_all_setup_and_model_calls(self):
        self.put("setup.sh", "echo started >> setup-count\n")
        first = self.make_entry("evals/first.yaml", setup_script="setup.sh")
        second = self.make_entry("evals/second.yaml", setup_script="setup.sh")
        self.put(second["config"], "models: {skill: model}\nthresholds: null\n")
        self.write_manifest([first, second])
        self.change_skill()

        result = self.run_step()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.claude_calls(), [])
        self.assertFalse((self.repo / "setup-count").exists())
        summary = json.loads((self.artifacts / "evals-summary.json").read_text())
        self.assertEqual([entry["status"] for entry in summary["evals"]], ["not_run", "failed"])
        self.assertIn(second["config"], summary["evals"][1]["failure"])
        self.assertTrue((self.eval_artifacts(first["config"]) / "config-resolution.log").is_file())
        self.assertIn("thresholds must",
                      (self.eval_artifacts(second["config"]) / "config-resolution.log").read_text())

    def test_missing_harness_config_api_is_a_preflight_failure(self):
        self.put("setup.sh", "echo started >> setup-count\n")
        self.entry["setup_script"] = "setup.sh"
        self.write_manifest([self.entry])
        self.change_skill()

        result = self.run_step(NO_CONFIG_API="1")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.claude_calls(), [])
        self.assertFalse((self.repo / "setup-count").exists())
        log = (self.eval_artifacts() / "config-resolution.log").read_text()
        self.assertIn("does not contain agent_eval/config.py", log)

    def test_malformed_resolver_result_is_rejected_by_parent(self):
        with self.assertRaisesRegex(runner.EvalError, "incompatible result schema"):
            config_bridge.validate_resolution_result({}, self.repo, self.entry["config"])

    def test_config_resolver_timeout_is_a_preflight_failure(self):
        self.put("setup.sh", "echo started >> setup-count\n")
        self.entry["setup_script"] = "setup.sh"
        self.write_manifest([self.entry])
        self.change_skill()
        entries, files = runner.select_manifest_entries(self.repo, self.env)
        env = {**self.env, "RESOLVER_SLEEP": "60"}
        self.artifacts.mkdir()
        with mock.patch.object(runner, "CONFIG_RESOLUTION_TIMEOUT", 0.05):
            status = runner.run_evals(self.repo, entries, files, self.artifacts, env)
        self.assertEqual(status, 1)
        self.assertEqual(self.claude_calls(), [])
        self.assertFalse((self.repo / "setup-count").exists())
        self.assertIn("timed out",
                      (self.eval_artifacts() / "config-resolution.log").read_text())

    def test_threshold_validation_at_verification_and_regression_boundaries(self):
        regression = load_sibling("eval_regression")
        self.put(self.entry["config"], "thresholds: null\n")
        with self.assertRaisesRegex(runner.EvalError, "thresholds must"):
            runner.verify_result(self.repo, {"thresholds": None})
        harness = self.make_fake_harness()
        original_import = regression.importlib.import_module
        def guarded_import(name, *args, **kwargs):
            if name == "score":
                raise AssertionError("score must not be imported")
            return original_import(name, *args, **kwargs)
        with mock.patch.object(sys, "argv", ["eval_regression", "--harness", str(harness),
                               "--repo", str(self.repo),
                               "--config", str(self.repo / self.entry["config"]),
                               "--run-dir", str(self.root)]), \
                mock.patch.object(regression.importlib, "import_module", side_effect=guarded_import):
            with self.assertRaisesRegex(runner.EvalError, "thresholds must"):
                regression.main()

    def test_invalid_manifest_entries(self):
        updates = [
            {"parallelism": 0}, {"parallelism": True}, {"parallelism": "5"},
            {"max_turns": -1}, {"max_turns": None}, {"max_turns": 1.5},
            {"run": "always"}, {"triggers": []}, {"triggers": "skills/foo/"},
            {"triggers": ["../outside/"]}, {"triggers": [""]},
            {"config": "missing.yaml"}, {"config": "../outside.yaml"},
            {"config": "/tmp/outside.yaml"}, {"config": "./evals/eval-foo.yaml"},
            {"setup_script": "missing.sh"}, {"setup_script": None},
            {"eval_cases_dir": "missing"}, {"eval_cases_dir": None},
            {"eval_cases_dir": ""}, {"eval_cases_dir": "../outside"},
            {"eval_cases_dir": "/tmp"}, {"eval_cases_dir": "./skills/foo"},
            {"eval_cases_dir": "evals/eval-foo.yaml"},
            {"unknown": "typo"},
        ]
        for update in updates:
            with self.subTest(update=update):
                self.write_manifest([{**self.entry, **update}])
                with self.assertRaises(runner.EvalError):
                    runner.load_manifest(self.repo)

    def test_malformed_empty_and_duplicate_yaml(self):
        for text in ("", "evals: null", "evals: {}", "evals: [", "evals: []\nevals: []"):
            with self.subTest(text=text):
                self.put("evals.yaml", text)
                result = self.run_step()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.calls(), [])

    def test_duplicate_config(self):
        self.write_manifest([self.entry, self.entry])
        with self.assertRaises(runner.EvalError):
            runner.load_manifest(self.repo)

    def test_symlink_cannot_escape_repository(self):
        outside = self.root / "outside.yaml"
        outside.write_text("models: {skill: model}")
        link = self.repo / "link.yaml"
        link.symlink_to(outside)
        self.write_manifest([{**self.entry, "config": "link.yaml"}])
        with self.assertRaises(runner.EvalError):
            runner.load_manifest(self.repo)

    def test_selected_eval_requires_models_skill_before_any_calls(self):
        self.put(self.entry["config"], "models: {judge: judge-model}\n")
        self.change_skill()
        result = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("models.skill",
                      (self.eval_artifacts() / "config-resolution.log").read_text())
        self.assertEqual(self.claude_calls(), [])

    def test_cases_directory_symlink_cannot_escape_repository(self):
        (self.repo / "outside-cases").symlink_to(self.root, target_is_directory=True)
        self.write_manifest([{**self.entry, "eval_cases_dir": "outside-cases"}])
        with self.assertRaises(runner.EvalError):
            runner.load_manifest(self.repo)

    def test_modes_and_extra_args_conflict(self):
        for overrides in ({"EVAL_CONFIG": "custom.yaml"}, {"EVAL_DISCOVER": "true"},
                          {"EVAL_EXTRA_ARGS": "--model override"}, {"JOB_TYPE": "periodic"},
                          {"JOB_TYPE": "postsubmit"}):
            with self.subTest(overrides=overrides):
                self.assertNotEqual(self.run_step(**overrides).returncode, 0)
                self.assertEqual(self.calls(), [])
