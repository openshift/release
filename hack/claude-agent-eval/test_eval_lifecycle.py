"""Fault injection for eval finalization, reporting, and control flow."""

import contextlib
import dataclasses
import json
from pathlib import Path
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
        entries, files = self.select_entries()
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
        entries, files = self.select_entries()
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
        entries, files = self.select_entries()
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
                    entries, files = fixture.select_entries()
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
        entries, files = self.select_entries()
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

    def test_reports_publish_text_utf8_cannot_encode(self):
        self.artifacts.mkdir()
        failure = "cannot collect summary.yaml: \udcff"  # for example an undecodable filename
        entries = [{"config": "evals/a.yaml", "name": "a", "run_id": "run-a",
                    "status": "failed", "failure": failure}]
        runner.write_summary(self.artifacts, entries, [failure])
        runner.write_index(self.artifacts, entries, [failure])
        summary = json.loads((self.artifacts / "evals-summary.json").read_text(encoding="utf-8"))
        self.assertEqual((summary["evals"][0]["failure"], summary["errors"]), (failure, [failure]))
        self.assertIn("\\udcff", self.index())
        self.assertEqual(list(self.artifacts.glob("*.tmp")), [])

    def test_failed_report_write_leaves_no_temporary_file(self):
        self.artifacts.mkdir()
        for writer in (runner.write_summary, runner.write_index):
            with self.subTest(writer=writer.__name__), \
                    mock.patch.object(Path, "replace", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    writer(self.artifacts, [], [])
            self.assertEqual(list(self.artifacts.glob("*.tmp")), [])

    def test_thresholds_edited_during_the_run_do_not_change_the_verdict(self):
        self.change_skill()
        result = self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: "tamper_thresholds"}))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("harness regression check failed", result.stdout)
        self.assertEqual(self.junit().attrib["failures"], "1")
        self.assertIn("REGRESSIONS: 1", (self.eval_artifacts() / "regression.log").read_text())
        tampered = yaml.safe_load((self.repo / self.entry["config"]).read_text())
        self.assertEqual(tampered["thresholds"], {"quality": {"min_pass_rate": 0.0}})

    def test_deadline_reached_after_verification_is_reported_as_the_step_limit(self):
        self.artifacts.mkdir()
        self.change_skill()
        entries, files = self.select_entries()
        verified = False
        verify, clock = runner.verify_result, runner.remaining

        def verify_then_expire(*args):
            nonlocal verified
            verify(*args)
            verified = True

        with mock.patch.object(runner, "verify_result", side_effect=verify_then_expire), \
                mock.patch.object(runner, "remaining",
                                  side_effect=lambda deadline: -1 if verified else clock(deadline)):
            self.assertEqual(runner.run_evals(self.repo, entries, files, self.artifacts, self.env), 1)
        self.assertNotIn("regression", self.calls())
        failure = self.junit().find("testcase/failure").attrib["message"]
        self.assertIn("step time limit reached before regression scoring", failure)
        self.assertNotIn("0.01 seconds", failure)


class HarnessPreparationTests(support.Fixture):
    def test_failed_harness_clone_has_junit(self):
        self.change_skill()
        self.assertNotEqual(self.run_step(CLONE_EXIT="1").returncode, 0)
        self.assertEqual(self.claude_calls(), [])
        self.assertEqual(self.junit().attrib["failures"], "1")
        self.assertEqual(json.loads((self.artifacts / "evals-summary.json").read_text())["evals"][0]["status"], "not_run")
        self.assertIn("runner/harness-install.log", self.index())
        self.assertIn("fake harness clone failed",
                      (self.artifacts / "runner/harness-install.log").read_text())

    def test_wrong_harness_revision_has_junit(self):
        self.change_skill()
        result = self.run_step(PINNED_HEAD="wrong")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.claude_calls(), [])
        self.assertEqual(self.junit().attrib["failures"], "1")
        install_log = (self.artifacts / "runner/harness-install.log").read_text()
        self.assertIn("revision mismatch", install_log)
        # The mismatch must name the revision and both revisions.
        self.assertIn(f"{self.env['EVAL_HARNESS_REVISION']} resolves to", install_log)
        self.assertIn("wrong", install_log)


class ConfigValidationTests(support.Fixture):
    def make_fake_harness(self):
        root = self.root / "standalone-harness"
        package = root / "agent_eval"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text("")
        (package / "config.py").write_text("""from pathlib import Path
from types import SimpleNamespace
import yaml
def load_raw(path):
    path = Path(path).resolve()
    return yaml.safe_load(path.read_text()) or {}, [str(path)]
class EvalConfig:
    @classmethod
    def from_yaml(cls, path):
        raw, _ = load_raw(path)
        value = cls()
        value.models = SimpleNamespace(skill=(raw.get('models') or {}).get('skill'))
        value.thresholds = raw.get('thresholds', {})
        value.dataset = SimpleNamespace(path=(raw.get('dataset') or {}).get('path', ''))
        value.resolve_path = lambda path: Path(path)
        value.resolve_skill = lambda: (raw.get('execution') or {}).get('skill') or raw.get('skill') or None
        value.eval_name = lambda: ((raw.get('execution') or {}).get('skill') or raw.get('skill')
                                   or raw.get('name') or Path(path).stem)
        return value
""")
        return root

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

    def test_resolved_skill_reaches_the_plan_through_the_bridge(self):
        harness = self.make_fake_harness()
        document = config_bridge.resolve_config(harness, self.repo, self.entry["config"]).as_dict()
        self.assertEqual(document["skill"], "example:foo")
        resolved = config_bridge.validate_resolution_result(document, self.repo, self.entry["config"])
        self.assertEqual((resolved["skill"], resolved["config_chain"]),
                         ("example:foo", (self.entry["config"],)))
        for change, message in (({"skill": ""}, "invalid skill"), ({"skill": 7}, "invalid skill"),
                                ({"schema_version": 2}, "unsupported schema_version")):
            with self.subTest(change=change), self.assertRaisesRegex(runner.EvalError, message):
                config_bridge.validate_resolution_result({**document, **change}, self.repo,
                                                         self.entry["config"])
        config_py = harness / "agent_eval/config.py"
        config_py.write_text(config_py.read_text().replace("value.resolve_skill =", "value.unused ="))
        for name in [name for name in sys.modules if name.split(".")[0] == "agent_eval"]:
            del sys.modules[name]  # Same checkout root, so the bridge would reuse the cached module.
        with self.assertRaisesRegex(runner.EvalError, "missing resolve_skill"):
            config_bridge.resolve_config(harness, self.repo, self.entry["config"])

    def test_config_resolver_timeout_is_a_preflight_failure(self):
        self.put("setup.sh", "echo started >> setup-count\n")
        self.entry["setup_script"] = "setup.sh"
        self.write_manifest([self.entry])
        self.change_skill()
        entries, files = self.select_entries()
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
        with self.assertRaisesRegex(runner.EvalError, "thresholds must"):
            runner.verify_result(self.repo, {"thresholds": None})
        harness = self.make_fake_harness()
        original_import = regression.importlib.import_module
        def guarded_import(name, *args, **kwargs):
            if name == "score":
                raise AssertionError("score must not be imported")
            return original_import(name, *args, **kwargs)
        for thresholds in ("null", "[]", "not json"):
            with self.subTest(thresholds=thresholds), \
                    mock.patch.object(sys, "argv", ["eval_regression", "--harness", str(harness),
                                      "--run-dir", str(self.root), "--thresholds", thresholds]), \
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


class RunIdentityTests(support.Fixture):
    """The run passes only if the harness ran the planned config, model, skill, and cases."""

    def run_behavior(self, behavior):
        self.calls_path.unlink(missing_ok=True)
        return self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: behavior}))

    def assert_identity_failure(self, behavior, *fragments):
        result = self.run_behavior(behavior)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.junit().attrib["failures"], "1")
        failure = self.junit().find("testcase/failure").attrib["message"]
        for fragment in fragments:
            self.assertIn(fragment, failure)
        self.assertNotIn("regression", self.calls())  # Never scored as if it were the planned run.
        return failure

    def test_matching_run_passes(self):
        self.change_skill()
        for behavior in ("pass", "absolute_chain"):
            with self.subTest(behavior=behavior):
                result = self.run_behavior(behavior)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.junit().attrib["failures"], "0")
                self.assertIn("regression", self.calls())
        recorded = json.loads((self.eval_artifacts() / "run_result.json").read_text())
        self.assertEqual(recorded["eval_params"]["skill"], "example:foo")
        self.assertEqual(list(recorded["per_case"]), ["case-001"])

    def test_substituted_fixed_config_fails(self):
        self.change_skill()  # Observed in CI: the orchestrator scored an edited copy.
        self.assert_identity_failure(
            "substituted_config", "harness evaluated config chain ['tmp/eval-foo-fixed.yaml'], "
            "but the runner planned ['evals/eval-foo.yaml']", "not a copied or edited file")

    def test_extra_extends_chain_file_fails(self):
        self.change_skill()
        self.assert_identity_failure(
            "extra_chain_file", "['evals/extra-base.yaml', 'evals/eval-foo.yaml']")

    def test_missing_extends_chain_file_fails(self):
        config = yaml.safe_load((self.repo / self.entry["config"]).read_text())
        self.put("evals/base.yaml", yaml.safe_dump(config))
        self.put(self.entry["config"], "extends: base.yaml\nmodels: {skill: overlay-model}\n")
        self.change_skill()
        result = self.run_behavior("pass")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.claude_calls()[0]["model"], "overlay-model")
        self.assert_identity_failure(
            "missing_chain_file", "harness evaluated config chain ['evals/eval-foo.yaml'], but the "
            "runner planned ['evals/base.yaml', 'evals/eval-foo.yaml']")

    def test_wrong_model_or_skill_fails(self):
        self.change_skill()
        self.assert_identity_failure(
            "wrong_model", "harness ran model 'other-model', but the runner planned 'model-from-eval'")
        self.assert_identity_failure(
            "wrong_skill", "harness ran skill 'other:skill', but the runner planned 'example:foo'")

    def test_missing_case_fails(self):
        self.put("evals/cases/eval-foo/case-002/input.yaml", "input: y\n")
        self.change_skill()
        self.assert_identity_failure("stop_early", "missing ['case-002'], unexpected []")

    def test_full_dataset_expected_set_follows_the_harness_workspace_rule(self):
        dataset = self.repo / "evals/cases/eval-foo"
        self.put("evals/cases/eval-foo/.hidden-case/input.yaml", "input: hidden\n")
        self.put("evals/cases/eval-foo/README.md", "not a case\n")
        (dataset / "linked-case").symlink_to("case-001", target_is_directory=True)
        self.change_skill()
        plan = runner.EvalPlan("evals/eval-foo.yaml", {}, "m", 1, 1, dataset_path=str(dataset))
        self.assertEqual(runner.planned_cases(plan), {".hidden-case", "case-001", "linked-case"})
        # A --cases request is the expected set; the harness must not widen or narrow it.
        self.assertEqual(runner.planned_cases(dataclasses.replace(plan, cases=("case-001",))),
                         {"case-001"})
        result = self.run_behavior("pass")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(self.claude_calls()[0]["cases"])
        recorded = json.loads((self.eval_artifacts() / "run_result.json").read_text())
        self.assertEqual(sorted(recorded["per_case"]), [".hidden-case", "case-001", "linked-case"])

    def test_absent_or_unverifiable_fields_fail_closed(self):
        self.change_skill()
        for behavior, fragment in (
                ("drop:eval_params", "no eval_params mapping"),
                ("drop:eval_params.config_chain", "eval_params.config_chain is missing or invalid"),
                ("drop:eval_params.execution_mode", "eval_params: None"),
                ("drop:model", "harness ran model None"),
                ("drop:eval_params.skill", "harness ran skill None, but the runner planned 'example:foo'"),
                ("drop:per_case", "run_result.json per_case is missing"),
                ("batch_mode", "execution_mode 'batch'"),
                ("summary_mismatch", "summary.yaml per_case does not match the planned cases: "
                                     "missing [], unexpected ['case-ghost']")):
            with self.subTest(behavior=behavior):
                self.assert_identity_failure(behavior, fragment)

    def test_prompt_mode_without_a_skill_passes_and_unset_dataset_fails_before_the_model(self):
        self.put(self.entry["config"], yaml.safe_dump({
            "name": "prompt-eval", "execution": {"prompt": "Answer {{ input.question }}"},
            "models": {"skill": "m"}, "dataset": {"path": "cases/eval-foo"}}))
        self.change_skill()
        result = self.run_behavior("pass")  # The harness omits eval_params.skill without one.
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.put(self.entry["config"], "models: {skill: m}\n")
        result = self.run_behavior("pass")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("dataset.path is unset", self.junit().find("testcase/failure").attrib["message"])
        self.assertEqual(self.claude_calls(), [])

    def test_full_dataset_run_over_an_empty_dataset_fails_closed(self):
        # Only a file, no case directories: an empty expectation would accept an
        # empty per_case, so the run must fail before the orchestrator starts.
        self.put("evals/cases/empty/README.md", "not a case\n")
        config = yaml.safe_load((self.repo / self.entry["config"]).read_text())
        self.put(self.entry["config"], yaml.safe_dump({**config, "dataset": {"path": "cases/empty"}}))
        self.change_skill()
        empty = self.repo / "evals/cases/empty"
        with self.assertRaisesRegex(runner.EvalError, "contains no case directories"):
            runner.planned_cases(runner.EvalPlan("c", {}, "m", 1, 1, dataset_path=str(empty)))
        result = self.run_behavior("pass")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"dataset.path {empty} contains no case directories",
                      self.junit().find("testcase/failure").attrib["message"])
        self.assertEqual(self.claude_calls(), [])


class CaseSubsetIdentityTests(support.Fixture):
    """A --cases run passes only if the harness ran exactly the requested cases."""

    def setUp(self):
        super().setUp()
        self.enable_case_subsets()

    def test_harness_running_unrequested_cases_fails(self):
        self.put("evals/cases/foo/case-001/input.yaml", "input: new\n")
        self.commit()
        # The orchestrator dropped --cases, so the harness ran the whole dataset.
        result = self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: "ignore_cases"}))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.claude_calls()[0]["cases"], ["case-001"])
        failure = self.junit().find("testcase/failure").attrib["message"]
        self.assertIn("run_result.json per_case does not match the planned cases: missing [], "
                      "unexpected ['case-002', 'case-003']", failure)
        self.assertNotIn("regression", self.calls())

    def test_requested_case_silently_dropped_by_the_harness_fails(self):
        # workspace.py keeps only existing directories named by --cases and
        # drops the rest without an error unless nothing matches.
        self.entry["setup_script"] = "setup.sh"
        self.put("setup.sh", "rm -r evals/cases/foo/case-003\n")
        self.write_manifest([self.entry])
        self.commit()
        base = self.git("rev-parse", "HEAD").strip()
        self.put("evals/cases/foo/case-001/input.yaml", "input: new\n")
        self.put("evals/cases/foo/case-003/input.yaml", "input: new\n")
        self.commit()
        result = self.run_step(PULL_BASE_SHA=base)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.claude_calls()[0]["cases"], ["case-001", "case-003"])
        failure = self.junit().find("testcase/failure").attrib["message"]
        self.assertIn("missing ['case-003'], unexpected []", failure)
