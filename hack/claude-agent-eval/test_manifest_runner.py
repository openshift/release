"""Offline tests of manifest behavior and the actual Prow shell entry point."""

import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock
from urllib.parse import unquote
import xml.etree.ElementTree as ET

import yaml


def load_sibling(name):
    """Load a sibling script regardless of the test or lint entry directory."""
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(f"{name}.py"))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


load_sibling("eval_plan")
report = load_sibling("eval_report")
runner = load_sibling("manifest_runner")
sync_commands = load_sibling("sync_commands")


FAKE_GIT = r'''
import os, pathlib, sys
if sys.argv[1] == "clone":
    with open(os.environ["CALLS"], "a") as out:
        out.write('clone\n')
    dest = pathlib.Path(sys.argv[-1])
    script = dest / "skills/eval-run/scripts/score.py"
    script.parent.mkdir(parents=True)
    script.write_text("import os, sys\n" +
                      "with open(os.environ['CALLS'], 'a') as out: out.write('regression\\n')\n" +
                      "sys.exit(int(os.environ.get('REGRESSION_EXIT', '0')))\n")
    sys.exit(int(os.environ.get("CLONE_EXIT", "0")))
os.execv(os.environ["REAL_GIT"], [os.environ["REAL_GIT"], *sys.argv[1:]])
'''

FAKE_CLAUDE = r'''
import json, os, pathlib, shlex, sys, time
if os.environ.get("WAIT_READY"):
    pathlib.Path(os.environ["WAIT_READY"]).write_text(str(os.getpid()))
    time.sleep(60)
args = sys.argv[1:]
prompt = shlex.split(args[args.index("-p") + 1])[1:]
def flag(name):
    return prompt[prompt.index(name) + 1]
config = flag("--config")
row = {"args": args, "config": config, "model": flag("--model"),
       "parallelism": flag("--parallelism"),
       "cases": prompt[prompt.index("--cases") + 1:] if "--cases" in prompt else None,
       "snapshot": os.environ.get("EVAL_SNAPSHOT_DIR"),
       "entrypoint": os.environ.get("CLAUDE_CODE_ENTRYPOINT")}
with open(os.environ["CALLS"], "a") as out:
    out.write(json.dumps(row) + "\n")
run_id = flag("--run-id")
root = pathlib.Path(os.environ.get("AGENT_EVAL_RUNS_DIR", "eval/runs"))
run = root / "skill-name-not-config-name" / run_id
run.mkdir(parents=True)
behavior = json.loads(os.environ.get("BEHAVIORS", "{}" )).get(config, "pass")
if behavior == "run_alias":
    alias = root / "config-name" / run_id
    alias.parent.mkdir(parents=True)
    alias.symlink_to(run, target_is_directory=True)
if behavior != "missing_result":
    result = {"exit_code": 1 if behavior == "case_failure" else 0}
    (run / "run_result.json").write_text(json.dumps(result))
if behavior != "missing_summary":
    (run / "summary.yaml").write_text('judges: {quality: {pass_rate: 1.0}}\n')
if behavior != "missing_report":
    (run / "report.html").write_text(config)
if behavior == "stale_result":
    for p in run.iterdir(): p.unlink()
    run.rmdir()
    stale = root / "other-eval" / "ci-stale"
    stale.mkdir(parents=True, exist_ok=True)
    (stale / "run_result.json").write_text('{"exit_code": 0}')
print('{"type": "result", "is_error": false}')
sys.exit(9 if behavior == "process_failure" else 0)
'''


class Fixture(unittest.TestCase):  # pylint: disable=too-many-instance-attributes
    commands = sync_commands.COMMANDS

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.artifacts = self.root / "artifacts"
        self.real_git = shutil.which("git")
        self.git("init", "-q")
        self.git("config", "user.name", "Eval Test")
        self.git("config", "user.email", "eval-test@example.invalid")
        self.put("skills/foo/SKILL.md", "old skill")
        self.put("skills/foobar/SKILL.md", "other skill")
        self.put("docs/guide.md", "old docs")
        self.entry = self.make_entry("evals/eval-foo.yaml")
        self.write_manifest([self.entry])
        self.commit()
        self.base = self.git("rev-parse", "HEAD").strip()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, source in (("git", FAKE_GIT), ("claude", FAKE_CLAUDE)):
            target = self.bin / name
            target.write_text(f"#!{sys.executable}\n" + source)
            target.chmod(0o755)
        # A symlink outside a venv can lose its pyvenv.cfg and installed PyYAML.
        # Re-exec the exact interpreter used to run this test suite instead.
        self.put_executable("python3", f"import os, sys\nos.execv({sys.executable!r}, "
                            f"[{sys.executable!r}, *sys.argv[1:]])\n")
        self.calls_path = self.root / "calls"
        self.last_result = None
        self.env = {
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(self.root), "REAL_GIT": self.real_git,
            "CALLS": str(self.calls_path),
            "EVAL_WORKDIR": str(self.repo), "PULL_BASE_SHA": self.base,
            "ARTIFACT_DIR": str(self.artifacts), "JOB_TYPE": "presubmit",
            "EVAL_CONFIG": "eval.yaml", "EVAL_DISCOVER": "",
            "EVAL_MODEL": "global-model-must-not-win", "EVAL_PARALLELISM": "99",
            "EVAL_MAX_TURNS": "99", "CLAUDE_MODEL": "outer-model",
            "CLAUDE_CONFIG_DIR": str(self.root / "claude"),
        }

    def put_executable(self, name, source):
        target = self.bin / name
        target.write_text(f"#!{sys.executable}\n" + source)
        target.chmod(0o755)

    def put(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        return target

    def git(self, *args):
        return subprocess.run([self.real_git, *args], cwd=self.repo, check=True,
                              capture_output=True, text=True).stdout

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def make_entry(self, config, **settings):
        self.put(config, yaml.safe_dump({
            "name": "example", "skill": "example:foo", "models": {"skill": "model-from-eval"},
            "execution": {"timeout": 17, "max_budget_usd": 0.25},
            "thresholds": {"quality": {"min_pass_rate": 1.0}},
        }))
        return {"config": config, "run": "pr", "parallelism": 5, "max_turns": 2500,
                "triggers": ["skills/foo/"], **settings}

    def write_manifest(self, entries):
        self.put("evals.yaml", yaml.safe_dump({"evals": entries}))

    def change_skill(self):
        self.put("skills/foo/SKILL.md", "new skill")
        self.commit()

    def run_step(self, *, cwd=None, **overrides):
        result = subprocess.run(["bash", str(self.commands)], cwd=cwd or self.root,
                                env={**self.env, **overrides}, capture_output=True,
                                text=True, timeout=20, check=False)
        self.last_result = result
        return result

    def calls(self):
        return self.calls_path.read_text().splitlines() if self.calls_path.exists() else []

    def claude_calls(self):
        return [json.loads(line) for line in self.calls() if line.startswith("{")]

    def eval_artifacts(self, config=None):
        config = config or self.entry["config"]
        name = runner.EvalPlan(config, {}, "model", 1, 1).artifact_name
        return self.artifacts / "evals" / name

    def index(self):
        return (self.artifacts / "evals-summary.html").read_text()

    def junit(self):
        return ET.parse(self.artifacts / "junit_claude-eval.xml").getroot()


class WorkdirTests(Fixture):
    def test_unset_workdir_uses_current_checkout(self):
        self.change_skill()
        del self.env["EVAL_WORKDIR"]
        result = self.run_step(cwd=self.repo)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.claude_calls()), 1)

    def test_empty_workdir_uses_current_checkout(self):
        self.change_skill()
        result = self.run_step(cwd=self.repo, EVAL_WORKDIR="")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.claude_calls()), 1)

    def test_explicit_workdir_overrides_current_directory(self):
        self.change_skill()
        for workdir in (str(self.repo), "repo"):
            with self.subTest(workdir=workdir):
                result = self.run_step(EVAL_WORKDIR=workdir)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.claude_calls()), 2)

    def test_invalid_current_directory_does_not_search_for_checkout(self):
        self.change_skill()
        result = self.run_step(EVAL_WORKDIR="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("manifest must reference an existing file", result.stdout)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.junit().attrib["failures"], "1")


class SelectionTests(Fixture):
    def test_no_match_has_no_clone_setup_or_claude_calls(self):
        setup = self.put("setup.sh", "touch should-not-exist\n")
        self.entry["setup_script"] = str(setup.relative_to(self.repo))
        self.write_manifest([self.entry])
        self.put("docs/guide.md", "new docs")
        self.commit()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.repo / "should-not-exist").exists())
        self.assertEqual(self.junit().attrib["tests"], "0")
        self.assertIn("SKIP evals/eval-foo.yaml", result.stdout)
        self.assertIn("No evaluations selected", self.index())

    def test_skill_only_change_runs_all_cases_with_owned_settings(self):
        original = (self.repo / self.entry["config"]).read_bytes()
        self.change_skill()
        result = self.run_step(EVAL_CHANGED_ONLY="true", EVAL_CASES="case-only", EVAL_EFFORT="low",
                               MULTISTAGE_PARAM_OVERRIDE_EVAL_MODEL="another-global-model")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call, = self.claude_calls()
        self.assertEqual(call["model"], "model-from-eval")
        self.assertEqual(call["parallelism"], "5")
        self.assertEqual(call["args"][call["args"].index("--max-turns") + 1], "2500")
        self.assertEqual(call["args"][call["args"].index("--model") + 1], "outer-model")
        self.assertNotIn("--cases", " ".join(call["args"]))
        self.assertNotIn("--effort", " ".join(call["args"]))
        self.assertEqual(call["entrypoint"], "sdk-cli")
        self.assertEqual((self.repo / self.entry["config"]).read_bytes(), original)
        self.assertIn("regression", self.calls())

    def test_literal_prefix_and_directory_boundary(self):
        entries = runner.load_manifest(self.repo)
        self.assertEqual(runner.select_evals(entries, ["skills/foobar/SKILL.md"]), [])
        self.assertEqual(runner.select_evals(entries, ["skills/foo/SKILL.md"]), entries)
        literal = runner.Eval("x.yaml", "pr", 1, 10, "", ("skills/a[1]/",))
        self.assertEqual(runner.select_evals([literal], ["skills/a1/file"]), [])
        self.assertEqual(runner.select_evals([literal], ["skills/a[1]/file"]), [literal])

    def test_periodic_and_manual_are_rejected_before_execution(self):
        for mode in ("periodic", "manual"):
            with self.subTest(mode=mode):
                entry = self.make_entry(f"evals/{mode}.yaml", run=mode)
                self.write_manifest([entry])
                result = self.run_step(PULL_BASE_SHA="")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("run must be pr", result.stdout)
                self.assertIn("run must be pr", self.index())
                self.assertEqual(self.calls(), [])
                self.assertEqual(self.junit().attrib["failures"], "1")

    def test_empty_manifest(self):
        self.write_manifest([])
        self.assertEqual(self.run_step(PULL_BASE_SHA="").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_bad_or_unavailable_base_sha_fails_without_model_calls(self):
        for base in ("", "not-a-sha", "1" * 40):
            with self.subTest(base=base):
                result = self.run_step(PULL_BASE_SHA=base)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.junit().attrib["failures"], "1")
                self.assertEqual(self.calls(), [])

    def test_manifest_edit_is_explicitly_triggered(self):
        self.entry["triggers"].append("evals.yaml")
        self.write_manifest([self.entry])
        self.commit()
        self.assertEqual(self.run_step().returncode, 0)
        self.assertEqual(len(self.claude_calls()), 1)

    def test_rename_and_deletion_match_original_path(self):
        self.git("mv", "skills/foo/SKILL.md", "docs/moved.md")
        self.commit()
        files = runner.changed_files(self.repo, self.base)
        self.assertIn("skills/foo/SKILL.md", files)
        self.assertIn("docs/moved.md", files)
        self.assertEqual(len(runner.select_evals(runner.load_manifest(self.repo), files)), 1)
        self.git("rm", "skills/foobar/SKILL.md")
        self.commit()
        self.assertIn("skills/foobar/SKILL.md", runner.changed_files(self.repo, self.base))

    def test_diff_preserves_spaces_and_newlines(self):
        self.put("skills/foo/space and\nnewline.md", "test")
        self.commit()
        self.assertIn("skills/foo/space and\nnewline.md", runner.changed_files(self.repo, self.base))

    def test_missing_git_metadata_is_failure_not_noop(self):
        result = self.run_step(EVAL_WORKDIR=str(self.repo / "skills"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])


class CaseSelectionTests(Fixture):
    def setUp(self):
        super().setUp()
        self.entry["eval_cases_dir"] = "evals/cases/foo/"
        self.entry["triggers"] += ["evals/cases/foo/", "evals/eval-foo.yaml", "evals.yaml"]
        config = yaml.safe_load((self.repo / self.entry["config"]).read_text())
        config["dataset"] = {"path": "cases/foo"}
        self.put(self.entry["config"], yaml.safe_dump(config))
        self.put("evals/cases/foo/case-001/input.yaml", "input: original\n")
        self.put("evals/cases/foo/case-002/input.yaml", "input: original\n")
        self.put("evals/cases/foo/case-003/input.yaml", "input: original\n")
        self.write_manifest([self.entry])
        self.commit()
        self.base = self.git("rev-parse", "HEAD").strip()
        self.env["PULL_BASE_SHA"] = self.base

    def test_only_changed_cases_are_passed_sorted_and_deduplicated(self):
        original = (self.repo / self.entry["config"]).read_bytes()
        self.put("evals/cases/foo/case-003/annotations.yaml", "expected: new\n")
        self.put("evals/cases/foo/case-001/input.yaml", "input: new\n")
        self.put("evals/cases/foo/case-001/fixtures/source.txt", "nested fixture")
        self.put("docs/guide.md", "unrelated change does not force a full run")
        self.commit()
        result = self.run_step(EVAL_CASES="case-002", EVAL_CHANGED_ONLY="false")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        call, = self.claude_calls()
        self.assertEqual(call["cases"], ["case-001", "case-003"])
        self.assertIn("changed cases", result.stdout)
        self.assertEqual((self.repo / self.entry["config"]).read_bytes(), original)

    def test_new_case_uses_exact_directory_name_with_spaces(self):
        self.put("evals/cases/foo/case-004 new example/input.yaml", "input: new\n")
        self.commit()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.claude_calls()[0]["cases"], ["case-004 new example"])

    def test_skill_and_case_changes_run_full_dataset(self):
        self.put("evals/cases/foo/case-001/input.yaml", "input: new\n")
        self.change_skill()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(self.claude_calls()[0]["cases"])
        self.assertIn("full dataset", result.stdout)

    def test_config_change_runs_full_dataset(self):
        config = self.repo / self.entry["config"]
        config.write_text(config.read_text() + "# updated eval\n")
        self.commit()
        self.assertEqual(self.run_step().returncode, 0)
        self.assertIsNone(self.claude_calls()[0]["cases"])

    def test_shared_manifest_and_setup_changes_invalidate_subset(self):
        self.put("setup.sh", "echo fixture\n")
        entry = runner.load_manifest(self.repo)[0]
        entry = runner.Eval(entry.config, entry.run, entry.parallelism, entry.max_turns,
                            "setup.sh", entry.triggers, entry.eval_cases_dir)
        for shared in ("evals/cases/foo/README.md", "evals.yaml", "setup.sh"):
            with self.subTest(shared=shared):
                files = ["evals/cases/foo/case-001/input.yaml", shared]
                self.assertIsNone(runner.select_cases(self.repo, entry, files))

    def test_removed_or_renamed_case_falls_back_to_full_dataset(self):
        self.git("mv", "evals/cases/foo/case-001", "evals/cases/foo/case-004")
        self.git("rm", "evals/cases/foo/case-002/input.yaml")
        self.commit()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIsNone(self.claude_calls()[0]["cases"])
        self.assertIn("removed case", result.stdout)

    def test_removed_fixture_in_surviving_case_still_selects_case(self):
        self.put("evals/cases/foo/case-001/fixture.txt", "old")
        self.commit()
        base = self.git("rev-parse", "HEAD").strip()
        self.git("rm", "evals/cases/foo/case-001/fixture.txt")
        self.commit()
        self.assertEqual(self.run_step(PULL_BASE_SHA=base).returncode, 0)
        self.assertEqual(self.claude_calls()[0]["cases"], ["case-001"])

    def test_case_directory_does_not_add_implicit_triggers(self):
        self.entry["triggers"] = ["skills/foo/"]
        self.write_manifest([self.entry])
        self.commit()
        base = self.git("rev-parse", "HEAD").strip()
        self.put("evals/cases/foo/case-001/input.yaml", "input: new\n")
        self.commit()
        result = self.run_step(PULL_BASE_SHA=base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.junit().attrib["tests"], "0")

    def test_dataset_mismatch_fails_before_any_calls(self):
        self.entry["eval_cases_dir"] = "skills/foo"
        self.write_manifest([self.entry])
        self.change_skill()
        result = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("same directory as dataset.path", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_case_filters_do_not_leak_between_evals(self):
        other = self.make_entry("evals/eval-bar.yaml", eval_cases_dir="evals/cases/bar",
                                triggers=["evals/cases/bar/"])
        config = yaml.safe_load((self.repo / other["config"]).read_text())
        config["dataset"] = {"path": "cases/bar"}
        self.put(other["config"], yaml.safe_dump(config))
        self.put("evals/cases/bar/case-005/input.yaml", "input: original\n")
        self.write_manifest([self.entry, other])
        self.commit()
        base = self.git("rev-parse", "HEAD").strip()
        self.put("evals/cases/foo/case-001/input.yaml", "input: new\n")
        self.put("evals/cases/bar/case-005/input.yaml", "input: new\n")
        self.commit()
        result = self.run_step(PULL_BASE_SHA=base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([c["cases"] for c in self.claude_calls()], [["case-001"], ["case-005"]])
        self.assertEqual(self.junit().attrib["tests"], "2")


class ValidationTests(Fixture):
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
        self.assertIn("models.skill", result.stdout)
        self.assertEqual(self.calls(), [])

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


class RunDirectoryTests(Fixture):
    def test_run_alias_preserves_reports_and_archive_contents(self):
        self.change_skill()
        result = self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: "run_alias"}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.junit().attrib["failures"], "0")
        self.assertTrue((self.eval_artifacts() / "report-summary.html").is_file())
        with tarfile.open(self.eval_artifacts() / "eval-run.tar") as archive:
            self.assertTrue(archive.getmember("run").isdir())
            self.assertTrue(archive.getmember("run/run_result.json").isfile())

    def test_flat_run_alias_resolves_to_the_same_directory(self):
        runs = self.repo / "eval/runs"
        directory = runs / "skill-name" / "current-run"
        directory.mkdir(parents=True)
        (runs / "current-run").symlink_to(directory, target_is_directory=True)
        self.assertEqual(runner.run_directory(runs, "current-run"), directory)

    def test_distinct_run_directories_remain_ambiguous(self):
        runs = self.repo / "eval/runs"
        for name in ("first", "second"):
            (runs / name / "current-run").mkdir(parents=True)
        with self.assertRaisesRegex(runner.EvalError, "found 2"):
            runner.run_directory(runs, "current-run")

    def test_run_alias_cannot_escape_runs_directory(self):
        runs = self.repo / "eval/runs"
        runs.mkdir(parents=True)
        (runs / "current-run").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(runner.EvalError, "escapes the runs directory"):
            runner.run_directory(runs, "current-run")


class ExecutionTests(Fixture):
    def test_setup_extra_artifacts_are_scoped_to_each_eval(self):
        self.put("setup.sh", 'echo prepared > "$ARTIFACT_DIR/extra.txt"\nprintf /tmp/snapshot\n')
        self.entry["setup_script"] = "setup.sh"
        other = self.make_entry("evals/other.yaml")
        self.write_manifest([self.entry, other])
        self.change_skill()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.eval_artifacts() / "extra.txt").read_text(), "prepared\n")
        self.assertFalse((self.eval_artifacts(other["config"]) / "extra.txt").exists())
        self.assertFalse((self.artifacts / "extra.txt").exists())

    def test_partial_run_is_archived_without_historical_results(self):
        self.put("eval/runs/old/old-run/old.txt", "historical")
        self.change_skill()
        result = self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: "missing_result"}))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads((self.artifacts / "evals-summary.json").read_text())["evals"][0]["status"], "failed")
        with tarfile.open(self.eval_artifacts() / "eval-run.tar") as archive:
            self.assertIn("run/report.html", archive.getnames())
            self.assertNotIn("run/run_result.json", archive.getnames())
            self.assertFalse(any("old" in name for name in archive.getnames()))
        self.assertFalse((self.eval_artifacts() / "run_result.json").exists())

    def test_collection_and_archive_failures_preserve_logs_and_next_eval(self):
        other = self.make_entry("evals/other.yaml")
        self.write_manifest([self.entry, other])
        self.change_skill()
        self.artifacts.mkdir()
        plans = runner.manifest_plans(self.repo, self.env)
        original_collect, original_archive = runner.collect_result, runner.archive

        def fail_collect(directory, artifacts):
            if artifacts == self.eval_artifacts():
                raise OSError("copy unavailable")
            return original_collect(directory, artifacts)

        def fail_archive(directory, artifacts):
            if artifacts == self.eval_artifacts():
                raise OSError("archive unavailable")
            return original_archive(directory, artifacts)

        with mock.patch.object(runner, "collect_result", side_effect=fail_collect), \
                mock.patch.object(runner, "archive", side_effect=fail_archive):
            env = {**self.env, "BEHAVIORS": json.dumps({self.entry["config"]: "missing_result"})}
            self.assertEqual(runner.run_evals(self.repo, plans, self.artifacts, env), 1)
        self.assertEqual(len(self.claude_calls()), 2)
        self.assertTrue((self.eval_artifacts() / "claude-eval.log").is_file())
        self.assertTrue((self.eval_artifacts(other["config"]) / "report-summary.html").is_file())
        self.assertIn("copy unavailable", self.index())
        self.assertIn("archive unavailable", self.index())
        self.assertIn("missing or invalid harness results", self.index())
        self.assertEqual(self.junit().attrib["failures"], "1")

    def test_index_escapes_text_and_only_links_existing_artifacts(self):
        self.artifacts.mkdir()
        entry = {"config": '<script>alert("x")</script>', "name": 'a & "b"',
                 "run_id": "run", "status": "failed", "failure": "bad <value>"}
        directory = self.artifacts / "evals" / entry["name"]
        directory.mkdir(parents=True)
        (directory / "claude-eval.log").write_text("log")
        runner.write_index(self.artifacts, [entry], ["runner <error>"])
        html = self.index()
        self.assertNotIn(entry["config"], html)
        self.assertIn("&lt;script&gt;", html)
        self.assertIn("bad &lt;value&gt;", html)
        self.assertIn("runner &lt;error&gt;", html)
        self.assertNotIn("report-summary.html", html)
        for href in re.findall(r'href="([^"]+)"', html):
            self.assertTrue((self.artifacts / unquote(href)).exists(), href)

    def test_index_failure_still_writes_failed_junit(self):
        self.artifacts.mkdir()
        results, errors = [], []
        with mock.patch.object(runner, "write_index", side_effect=OSError("disk error")):
            runner.write_reports(self.artifacts, results, [], errors)
        self.assertEqual(self.junit().attrib["failures"], "1")
        self.assertIn("disk error", errors[0])
        summary = json.loads((self.artifacts / "evals-summary.json").read_text())
        self.assertEqual(summary["status"], "failed")
        self.assertIn("disk error", summary["errors"][0])

    def test_run_artifacts_are_kept_without_global_session_archive(self):
        sessions = Path(self.env["CLAUDE_CONFIG_DIR"]) / "projects"
        sessions.mkdir(parents=True)
        (sessions / "unrelated-session.jsonl").write_text("existing session")
        self.change_skill()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive_path = self.eval_artifacts() / "eval-run.tar"
        with tarfile.open(archive_path, "r:") as archive:
            self.assertTrue(archive.getmember("run/run_result.json").isfile())
        self.assertIn("/eval-run.tar\"", self.index())
        self.assertNotIn("eval-run.tar.gz", self.index())
        self.assertTrue((self.eval_artifacts() / "report-summary.html").is_file())
        self.assertTrue((self.eval_artifacts() / "claude-eval.log").is_file())
        self.assertFalse((self.artifacts / "claude-sessions.tar.gz").exists())
        self.assertEqual((sessions / "unrelated-session.jsonl").read_text(), "existing session")

    def test_distributed_commands_run_without_sibling_sources_and_clean_up(self):
        standalone = self.root / "commands.sh"
        standalone.write_bytes(sync_commands.COMMANDS.read_bytes())
        bundle_tmp = self.root / "bundles"
        bundle_tmp.mkdir()
        self.change_skill()
        result = subprocess.run(["bash", str(standalone)], cwd=self.root,
                                env={**self.env, "TMPDIR": str(bundle_tmp)},
                                capture_output=True, text=True, timeout=20, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.claude_calls()), 1)
        self.assertEqual(list(bundle_tmp.iterdir()), [])

    def test_termination_reaches_python_and_preserves_junit(self):
        self.change_skill()
        ready = self.root / "ready"
        bundle_tmp = self.root / "bundles"
        bundle_tmp.mkdir()
        env = {**self.env, "WAIT_READY": str(ready), "TMPDIR": str(bundle_tmp)}
        with subprocess.Popen(["bash", str(sync_commands.COMMANDS)], cwd=self.root,
                              env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as process:
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(ready.exists(), "fake Claude never started")
                process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=10)
            finally:
                if process.poll() is None:
                    process.kill()
        self.assertEqual(process.returncode, 143, stdout + stderr)
        self.assertIn("interrupted by signal", stdout)
        self.assertGreater(int(self.junit().attrib["failures"]), 0)
        self.assertEqual(json.loads((self.artifacts / "evals-summary.json").read_text())["evals"][0]["status"], "failed")
        self.assertIn("interrupted by signal", self.index())
        self.assertEqual(list(bundle_tmp.iterdir()), [])
        with self.assertRaises(ProcessLookupError):
            os.kill(int(ready.read_text()), 0)

    def test_two_evals_have_separate_settings_artifacts_and_setup_environment(self):
        self.put("setup.sh", 'echo "fixture prepared" >&2\nprintf /tmp/fixture-foo\n')
        first = self.make_entry("one/eval-same.yaml", setup_script="setup.sh")
        second = self.make_entry("two/eval-same.yaml", parallelism=2, max_turns=31)
        self.write_manifest([first, second])
        self.change_skill()
        result = self.run_step(EVAL_SNAPSHOT_DIR="stale-global-value")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.claude_calls()
        self.assertEqual([c["config"] for c in calls], [first["config"], second["config"]])
        self.assertEqual([c["parallelism"] for c in calls], ["5", "2"])
        self.assertEqual([c["snapshot"] for c in calls], ["/tmp/fixture-foo", None])
        reports = list(self.artifacts.glob("evals/eval-same-*/report-summary.html"))
        self.assertEqual(len(reports), 2)
        self.assertEqual({r.read_text() for r in reports}, {first["config"], second["config"]})
        self.assertEqual(len(list(self.artifacts.glob("evals/*/summary.yaml"))), 2)
        self.assertEqual(self.junit().attrib["tests"], "2")
        for entry in (first, second):
            with tarfile.open(self.eval_artifacts(entry["config"]) / "eval-run.tar") as archive:
                self.assertEqual(archive.extractfile("run/report.html").read().decode(), entry["config"])
                self.assertEqual(sum(n.endswith("report.html") for n in archive.getnames()), 1)
        self.assertFalse((self.artifacts / "eval-runs.tar.gz").exists())
        self.assertEqual({p.name for p in self.artifacts.iterdir() if p.is_file()},
                         {"junit_claude-eval.xml", "evals-summary.html", "evals-summary.json"})
        for href in re.findall(r'href="([^"]+)"', self.index()):
            self.assertTrue((self.artifacts / unquote(href)).exists(), href)
        self.assertEqual(json.loads((self.artifacts / "evals-summary.json").read_text())["counts"]["passed"], 2)

    def test_same_setup_script_runs_for_each_eval_with_its_own_snapshot(self):
        self.put("setup.sh", 'echo setup >> setup-count\n'
                 'printf "/tmp/snapshot-%s" "$(wc -l < setup-count | tr -d \' \')"\n')
        first = self.make_entry("evals/first.yaml", setup_script="setup.sh")
        second = self.make_entry("evals/second.yaml", setup_script="setup.sh")
        self.write_manifest([first, second])
        self.change_skill()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.repo / "setup-count").read_text().splitlines(), ["setup", "setup"])
        self.assertEqual([call["snapshot"] for call in self.claude_calls()],
                         ["/tmp/snapshot-1", "/tmp/snapshot-2"])

    def test_setup_failure_is_reported_and_next_eval_runs(self):
        self.put("setup.sh", "echo failed >&2\nexit 12\n")
        self.entry["setup_script"] = "setup.sh"
        other = self.make_entry("evals/other.yaml")
        self.write_manifest([self.entry, other])
        self.change_skill()
        self.assertNotEqual(self.run_step().returncode, 0)
        self.assertEqual([c["config"] for c in self.claude_calls()], [other["config"]])
        self.assertEqual(self.junit().attrib["tests"], "2")
        self.assertEqual(self.junit().attrib["failures"], "1")

    def test_process_case_and_incomplete_results_are_failures(self):
        self.change_skill()
        for behavior in ("process_failure", "case_failure", "missing_result", "missing_summary",
                         "missing_report", "stale_result"):
            with self.subTest(behavior=behavior):
                result = self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: behavior}))
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.junit().attrib["failures"], "1")

    def test_threshold_failure_changes_ci_verdict(self):
        self.change_skill()
        result = self.run_step(REGRESSION_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("harness regression check failed", result.stdout)
        self.assertEqual(self.junit().attrib["failures"], "1")

    def test_missing_thresholded_judge_is_failure(self):
        self.put(self.entry["config"], "models: {skill: model}\nthresholds: {missing: {min_mean: 1}}")
        self.change_skill()
        self.assertNotEqual(self.run_step().returncode, 0)
        self.assertIn("missing thresholded judge", self.last_result.stdout)

    def test_failed_clone_has_junit(self):
        self.change_skill()
        self.assertNotEqual(self.run_step(CLONE_EXIT="1").returncode, 0)
        self.assertEqual(self.claude_calls(), [])
        self.assertEqual(self.junit().attrib["failures"], "1")
        self.assertEqual(json.loads((self.artifacts / "evals-summary.json").read_text())["evals"][0]["status"], "not_run")
        self.assertIn("runner/harness-install.log", self.index())

    def test_junit_escapes_config_paths(self):
        entry = self.make_entry('evals/eval-foo & "bar".yaml')
        self.write_manifest([entry])
        self.change_skill()
        self.assertEqual(self.run_step().returncode, 0)
        self.assertIn(entry["config"], self.junit().find("testcase").attrib["name"])

    def test_command_timeout_kills_process(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            runner.command([sys.executable, "-c", "import time; time.sleep(60)"], self.repo,
                           self.env, self.root / "timeout.log", 0.05)

    def test_step_deadline_does_not_silently_drop_evals(self):
        self.artifacts.mkdir()
        self.change_skill()
        entries = runner.manifest_plans(self.repo, self.env)
        with mock.patch.object(runner, "STEP_TIMEOUT", -1), mock.patch.object(runner, "command", return_value=0):
            self.assertEqual(runner.run_evals(self.repo, entries, self.artifacts, self.env), 1)
        self.assertEqual(self.junit().attrib["failures"], "1")

    def test_metrics_run_in_python_without_exported_shell_functions(self):
        with mock.patch.object(runner, "command", return_value=0) as command:
            runner.emit_metrics(self.env, self.repo, self.artifacts, self.eval_artifacts(),
                                stream_log=self.root / "stream.log", result=None,
                                run_id="example", prompt="/eval-run")
        args = command.call_args.args[0]
        self.assertEqual(args[0], sys.executable)
        self.assertEqual(Path(args[1]).name, "eval_metrics.py")
        self.assertEqual(args[-2:], ["example", "/eval-run"])
        self.assertEqual(args[5], str(self.artifacts / "claude-session-metrics-autodl.json"))
        self.assertEqual(command.call_args.args[3], self.eval_artifacts() / "metrics.log")


class SummaryTests(Fixture):
    """Machine-readable result contract and reporting failures."""

    def test_json_summary_status_and_partial_artifacts(self):
        self.artifacts.mkdir()
        entries = [{"config": "evals/a.yaml", "name": "a", "run_id": "run-a",
                    "status": "failed", "failure": "bad <result>"},
                   {"config": "evals/b.yaml", "name": "b", "run_id": "",
                    "status": "not run", "failure": ""}]
        directory = self.artifacts / "evals/a"
        directory.mkdir(parents=True)
        (directory / "claude-eval.log").write_text("partial")
        runner.write_summary(self.artifacts, entries, [])
        summary = json.loads((self.artifacts / "evals-summary.json").read_text())
        self.assertEqual(summary["schema_version"], 1)
        self.assertEqual(summary["status"], "failed")
        self.assertEqual(summary["counts"], {"selected": 2, "passed": 0, "failed": 1, "not_run": 1})
        self.assertEqual(summary["evals"][0]["failure"], "bad <result>")
        self.assertEqual(summary["evals"][0]["artifacts"],
                         {"claude-eval.log": "evals/a/claude-eval.log"})
        self.assertIsNone(summary["evals"][1]["run_id"])
        self.assertIsNone(summary["evals"][1]["artifact_dir"])
        self.assertEqual(runner.summary_data(self.artifacts, [], [])["status"], "no_evals")
        self.assertEqual(runner.summary_data(self.artifacts, [], ["bad config"])["status"], "failed")
        self.assertEqual(runner.summary_data(self.artifacts, entries[1:], [])["status"], "not_run")
        entries[0].update(status="passed", failure="")
        self.assertEqual(runner.summary_data(self.artifacts, entries[:1], [])["status"], "passed")

    def test_json_failure_does_not_prevent_other_reports(self):
        self.artifacts.mkdir()
        results, errors = [], []
        with mock.patch.object(runner, "write_summary", side_effect=OSError("JSON unavailable")):
            runner.write_reports(self.artifacts, results, [], errors)
        self.assertIn("JSON unavailable", self.index())
        self.assertEqual(self.junit().attrib["failures"], "1")

    def test_html_renders_saved_json_without_inspecting_eval_files(self):
        self.artifacts.mkdir()
        entry = {"config": '<img src=x onerror=alert(1)>', "name": 'a & "b"',
                 "run_id": "run-a", "status": "failed", "failure": "bad </script>"}
        summary = runner.summary_data(self.artifacts, [entry], ["runner <error>"])
        summary["evals"][0]["artifacts"] = {"log": 'evals/a & "b"/claude-eval.log'}
        source = self.artifacts / "evals-summary.json"
        source.write_text(json.dumps(summary))
        output = self.artifacts / "evals-summary.html"
        subprocess.run([sys.executable, str(Path(report.__file__)), str(source), str(output)], check=True)
        html = output.read_text()
        self.assertEqual(html, report.render_report(summary))
        self.assertIn('class="fail">Failed', html)
        self.assertIn('&lt;img src=x onerror=alert(1)&gt;', html)
        self.assertIn('bad &lt;/script&gt;', html)
        self.assertIn('evals/a%20%26%20%22b%22/claude-eval.log', html)
        self.assertNotIn(entry["config"], html)
        self.assertIn('href="evals-summary.json"', html)
        self.assertIn('gcs.ci.openshift.org', html)
        with self.assertRaises(ValueError):
            report.artifact_link("../outside.log", "log")
        with self.assertRaises(ValueError):
            report.render_report({**summary, "schema_version": 2})


class PackagingTests(unittest.TestCase):
    def test_bundled_source_is_current(self):
        self.assertEqual(sync_commands.COMMANDS.read_text(), sync_commands.generated_script())

    def test_manifest_workflow_has_its_own_execution_step(self):
        directory = sync_commands.COMMANDS.parent
        workflow = yaml.safe_load((directory / "openshift-claude-agent-eval-manifest-workflow.yaml").read_text())
        self.assertEqual(workflow["workflow"]["steps"]["test"],
                         [{"ref": "openshift-claude-agent-eval-manifest"}])
        self.assertNotIn("post", workflow["workflow"]["steps"])
        legacy = yaml.safe_load((directory.parent / "openshift-claude-agent-eval-workflow.yaml").read_text())
        self.assertEqual(legacy["workflow"]["steps"]["test"], [{"ref": "openshift-claude-agent-eval"}])


if __name__ == "__main__":
    unittest.main()
