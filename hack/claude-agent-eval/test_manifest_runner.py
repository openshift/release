"""Offline tests of manifest behavior and the actual Prow shell entry point."""  # pylint: disable=too-many-lines

import atexit
import copy
import functools
import hashlib
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
changes = load_sibling("eval_changes")
config_bridge = load_sibling("eval_config")
report = load_sibling("eval_report")
runner = load_sibling("manifest_runner")
sync_commands = load_sibling("sync_commands")
TESTING = Path(__file__).resolve().with_name("testing")
_fake_spec = importlib.util.spec_from_file_location("fake_github", TESTING / "fake_github.py")
assert _fake_spec and _fake_spec.loader
fake_github = importlib.util.module_from_spec(_fake_spec)
_fake_spec.loader.exec_module(fake_github)
ORG, REPO, PULL = "openshift-eng", "example", 7
GIT_STATUS = {"A": "added", "D": "removed", "M": "modified", "R": "renamed", "C": "copied", "T": "changed"}


def isolated_git_env(env):
    """Keep fixture Git off the host's config, e.g. a developer's commit signing or hooks.

    GIT_CONFIG_GLOBAL replaces both ~/.gitconfig and $XDG_CONFIG_HOME/git/config.
    """
    env = {key: value for key, value in env.items() if not key.startswith("GIT_CONFIG")}
    return {**env, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}


FAKE_GIT = r'''
import os, pathlib, sys
args = sys.argv[1:]
if "clone" in args:  # The runner's only clone is the harness release.
    with open(os.environ["CALLS"], "a") as out:
        out.write('harness-clone\n')
    status = int(os.environ.get("CLONE_EXIT", "0"))
    if status:
        print('fake harness clone failed', file=sys.stderr)
        sys.exit(status)
    dest = pathlib.Path(args[-1])
    dest.mkdir(parents=True)
    if not os.environ.get("NO_CONFIG_API"):
        package = dest / "agent_eval"
        package.mkdir(parents=True)
        (package / "__init__.py").write_text("")
        (package / "config.py").write_text("""from pathlib import Path
import os, time
class EvalConfig:
    def __init__(self, raw, chain):  # Paths resolve from the chain root, as in the harness.
        self.models = type('Models', (), {'skill': (raw.get('models') or {}).get('skill')})()
        self.thresholds = raw.get('thresholds', {})
        self.dataset = type('Dataset', (), {'path': (raw.get('dataset') or {}).get('path', '')})()
        self.base = Path(chain[0]).parent
        self.raw, self.stem = raw, Path(chain[0]).stem
    def resolve_skill(self):
        return (self.raw.get('execution') or {}).get('skill') or self.raw.get('skill') or None
    def eval_name(self):  # Same priority as the harness: skill under test, then name, then stem.
        return self.resolve_skill() or self.raw.get('name') or self.stem
    def resolve_path(self, value):
        path = Path(value)
        return path if path.is_absolute() else self.base / path
    @classmethod
    def from_yaml(cls, path):
        return cls(*load_raw(path))
def load_raw(path):
    import yaml
    time.sleep(float(os.environ.get('RESOLVER_SLEEP', '0')))
    path = Path(path).resolve()
    raw = yaml.safe_load(path.read_text()) or {}
    if not isinstance(raw, dict):
        raise ValueError('config must be a mapping')
    if 'extends' not in raw:
        return raw, [str(path)]
    merged, chain = load_raw(path.parent / raw.pop('extends'))
    return {**merged, **raw}, [*chain, str(path)]
""")
    script = dest / "skills/eval-run/scripts/score.py"
    script.parent.mkdir(parents=True)
    script.write_text("""import os
from types import SimpleNamespace
def detect_regressions(judges, thresholds):
    with open(os.environ['CALLS'], 'a') as out: out.write('regression\\n')
    return [SimpleNamespace(judge_name=name, metric='pass_rate', baseline_value=limit['min_pass_rate'],
                            current_value=judges[name]['pass_rate'])
            for name, limit in thresholds.items()
            if judges[name]['pass_rate'] < limit['min_pass_rate']]
""")
    sys.exit(0)
if args[0] == "-C" and args[2] == "rev-parse":
    with open(os.environ["CALLS"], "a") as out: out.write('harness-rev-parse\n')
    print(os.environ["EVAL_HARNESS_REVISION"], os.environ.get("PINNED_HEAD", os.environ["EVAL_HARNESS_REVISION"]), sep="\n")
    sys.exit(0)
# Changed files come from the GitHub API; the runner must not read the checkout's Git.
with open(os.environ["CALLS"], "a") as out: out.write('unexpected-git ' + ' '.join(args) + '\n')
print('fake git: unexpected call: ' + ' '.join(args), file=sys.stderr)
sys.exit(97)
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
behavior = json.loads(os.environ.get("BEHAVIORS", "{}" )).get(config, "pass")
import functools, yaml
from agent_eval.config import EvalConfig, load_raw  # The fake harness checkout on PYTHONPATH.
raw = yaml.safe_load(pathlib.Path(config).read_text()) or {}
harness_config = EvalConfig.from_yaml(config)  # Runs are named after its eval_name(), never a guess.
chain = [os.path.relpath(p) for p in load_raw(config)[1]]  # Recorded relative to the harness's cwd.
chain = {"substituted_config": [f"tmp/{pathlib.Path(config).stem}-fixed.yaml"],  # An edited copy (CI).
         "extra_chain_file": ["evals/extra-base.yaml", *chain], "missing_chain_file": chain[1:],
         "absolute_chain": [os.path.abspath(item) for item in chain]}.get(behavior, chain)
case_ids = sorted(d.name for d in harness_config.resolve_path(harness_config.dataset.path).iterdir() if d.is_dir())
# workspace.py's rule: a nonempty --cases keeps matching directories and silently drops unknown IDs.
case_ids = [case for case in case_ids if not row["cases"] or behavior == "ignore_cases" or case in row["cases"]]
case_ids = case_ids[:-1] if behavior == "stop_early" else case_ids
skill = "other:skill" if behavior == "wrong_skill" else harness_config.resolve_skill()
mode = "batch" if behavior == "batch_mode" else "case"  # Batch runs record no per-case results.
eval_params = {"execution_mode": mode, "config_chain": chain, **({"skill": skill} if skill else {})}
run_result = {"exit_code": 1 if behavior == "case_failure" else 0, "execution_mode": mode, "eval_params": eval_params,
              "model": "other-model" if behavior == "wrong_model" else row["model"],
              **({} if mode == "batch" else {"per_case": {case: {"exit_code": 0} for case in case_ids}})}
if behavior.startswith("drop:"):
    *parents, field = behavior[len("drop:"):].split(".")
    del functools.reduce(dict.get, parents, run_result)[field]
run = root / ("config-name" if behavior == "wrong_name_only" else harness_config.eval_name()) / run_id
run.mkdir(parents=True)
if behavior == "run_alias":
    alias = root / "config-name" / run_id
    alias.parent.mkdir(parents=True)
    alias.symlink_to(run, target_is_directory=True)
if behavior != "missing_result":
    (run / "run_result.json").write_text(json.dumps(run_result))
if behavior == "tamper_thresholds": pathlib.Path(config).write_text(yaml.safe_dump({**raw, "thresholds": {"quality": {"min_pass_rate": 0.0}}}))
if behavior != "missing_summary":
    rate = 0.0 if behavior in ("threshold_failure", "tamper_thresholds") else 1.0
    scored = case_ids + ["case-ghost"] if behavior == "summary_mismatch" else case_ids
    (run / "summary.yaml").write_text(yaml.safe_dump({"judges": {"quality": {"pass_rate": rate}}, "per_case": dict.fromkeys(scored, {})}))
if behavior == "removed_alias":
    alias = root / "config-name"
    alias.symlink_to(run.parent, target_is_directory=True)
    alias.unlink()
if behavior != "missing_report":
    (run / "report.html").write_text(config)
if behavior == "copied_run":  # A physical duplicate under the guessed name (release#85928).
    __import__("shutil").copytree(run, root / "config-name" / run_id)
if behavior == "stale_result":
    for p in run.iterdir(): p.unlink()
    run.rmdir()
    stale = root / "other-eval" / "ci-stale"
    stale.mkdir(parents=True, exist_ok=True)
    (stale / "run_result.json").write_text('{"exit_code": 0}')
print('{"type": "result", "is_error": false}')
sys.exit(9 if behavior == "process_failure" else 0)
'''


class Fixture(unittest.TestCase):  # pylint: disable=too-many-instance-attributes,too-many-public-methods
    commands = sync_commands.COMMANDS

    @staticmethod
    @functools.lru_cache(maxsize=None)
    def base_repository():
        """Build the committed base repository once; each test copies it.

        Copying skips git init/config/add/commit per test, and every copy keeps
        the same base SHA. Built on first use, so a Fixture constructed directly
        gets it too.
        """
        template = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        atexit.register(template.cleanup)
        builder = Fixture()  # Only the repository helpers are used.
        builder.repo = Path(template.name).resolve() / "repo"
        builder.repo.mkdir()
        builder.real_git = shutil.which("git")
        builder.git("init", "-q")
        builder.git("config", "user.name", "Eval Test")
        builder.git("config", "user.email", "eval-test@example.invalid")
        builder.put("skills/foo/SKILL.md", "old skill")
        builder.put("skills/foobar/SKILL.md", "other skill")
        builder.put("docs/guide.md", "old docs")
        entry = builder.make_entry("evals/eval-foo.yaml")
        builder.write_manifest([entry])
        builder.commit()
        return builder.repo, builder.git("rev-parse", "HEAD").strip(), entry

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        # Fixture Git runs with this process's environment.
        environ = mock.patch.dict(os.environ, isolated_git_env(os.environ), clear=True)
        environ.start()
        self.addCleanup(environ.stop)
        self.repo = self.root / "repo"
        base_repo, self.base, entry = self.base_repository()
        shutil.copytree(base_repo, self.repo, symlinks=True)
        self.entry = copy.deepcopy(entry)
        self.artifacts = self.root / "artifacts"
        self.real_git = shutil.which("git")
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
        self.github_log = self.root / "github-requests.jsonl"
        self.last_result = None
        self.github_fixture_override = None
        self.fake_api = None
        self.github_responses = {}
        self.env = {
            **isolated_git_env({}),
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "HOME": str(self.root),
            "CALLS": str(self.calls_path),
            "EVAL_HARNESS_REVISION": "v1.0.0",
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
                              capture_output=True, text=True, env=isolated_git_env(os.environ)).stdout

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def make_entry(self, config, **settings):
        stem = Path(config).stem  # Each eval gets a one-case dataset, as real evals have.
        self.put(config, yaml.safe_dump({
            "name": "example", "skill": "example:foo", "models": {"skill": "model-from-eval"},
            "execution": {"timeout": 17, "max_budget_usd": 0.25},
            "dataset": {"path": f"cases/{stem}"},
            "thresholds": {"quality": {"min_pass_rate": 1.0}},
        }))
        self.put((Path(config).parent / "cases" / stem / "case-001/input.yaml").as_posix(), "input: x\n")
        return {"config": config, "run": "pr", "parallelism": 5, "max_turns": 2500,
                "triggers": ["skills/foo/"], **settings}

    def enable_case_subsets(self):  # Changed case directories can then select a --cases subset.
        self.entry["eval_cases_dir"] = "evals/cases/foo/"
        self.entry["triggers"] += ["evals/cases/foo/", "evals/eval-foo.yaml", "evals.yaml"]
        config = yaml.safe_load((self.repo / self.entry["config"]).read_text())
        config["dataset"] = {"path": "cases/foo"}
        self.put(self.entry["config"], yaml.safe_dump(config))
        for case in ("case-001", "case-002", "case-003"):
            self.put(f"evals/cases/foo/{case}/input.yaml", "input: original\n")
        self.write_manifest([self.entry])
        self.commit()
        self.env["PULL_BASE_SHA"] = self.base = self.git("rev-parse", "HEAD").strip()

    def write_manifest(self, entries):
        self.put("evals.yaml", yaml.safe_dump({"evals": entries}))

    def change_skill(self):
        self.put("skills/foo/SKILL.md", "new skill")
        self.commit()

    def head(self):
        return self.git("rev-parse", "HEAD").strip()

    def pull_files(self, base):
        """GitHub's file list for base...HEAD: what GET /pulls/{n}/files reports."""
        if not base:
            return []
        fields = self.git("diff", "--name-status", "-z", "-M", f"{base}...HEAD", "--").split("\0")
        files = []
        while fields and fields[0]:
            code = fields.pop(0)
            entry = {"status": GIT_STATUS[code[0]]}
            if code[0] in "RC":
                entry["previous_filename"] = fields.pop(0)
            entry["filename"] = fields.pop(0)
            files.append(entry)
        return files

    def github_fixture(self, base):
        if self.github_fixture_override is not None:
            return self.github_fixture_override
        return {"pulls": {f"{ORG}/{REPO}#{PULL}": {"head_sha": self.head(), "files": self.pull_files(base)}},
                "responses": copy.deepcopy(self.github_responses)}

    def job_spec(self, job_type="presubmit", pulls=None):
        pulls = pulls if pulls is not None else [{"number": PULL, "sha": self.head(), "author": "dev"}]
        return json.dumps({"type": job_type, "job": "pull-ci-openshift-eng-example-main-eval-runner",
                           "buildid": "1", "prowjobid": "id",
                           "refs": {"org": ORG, "repo": REPO, "base_ref": "main", "base_sha": self.env["PULL_BASE_SHA"],
                                    "pulls": pulls}})

    def prow_env(self, overrides=None):
        """Prow's job environment for the current head; JOB_SPEC is generated unless given."""
        env = {**self.env, **(overrides or {})}
        if "JOB_SPEC" not in env:
            env["JOB_SPEC"] = self.job_spec(env.get("JOB_TYPE") or "presubmit")
        return env

    def step_env(self, **overrides):
        """The entry point's environment, with the fake GitHub API on PYTHONPATH."""
        env = self.prow_env(overrides)
        fixture = self.root / "github-fixture.json"
        fixture.write_text(json.dumps(self.github_fixture(env.get("PULL_BASE_SHA", ""))))
        return {**env, "EVAL_TEST_GITHUB_FIXTURE": str(fixture), "EVAL_TEST_GITHUB_LOG": str(self.github_log),
                "PYTHONPATH": str(TESTING)}

    def github(self, **kwargs):
        """An API client reading the fixture through an injected fake opener."""
        self.fake_api = fake_github.FakeGitHub(self.github_fixture(self.env.get("PULL_BASE_SHA", "")))
        return changes.GitHubAPI("", opener=self.fake_api, sleep=lambda seconds: None, **kwargs)

    def select_entries(self, **overrides):
        return runner.select_manifest_entries(self.repo, self.prow_env(overrides), github=self.github())

    def github_requests(self):
        return ([json.loads(line) for line in self.github_log.read_text().splitlines()]
                if self.github_log.exists() else [])

    def run_step(self, *, cwd=None, **overrides):
        """Run the generated entry point with no .git in the workdir, as in Prow."""
        env = self.step_env(**overrides)
        hidden = self.root / "hidden.git"
        git_dir = self.repo / ".git"
        moved = git_dir.exists()
        if moved:
            git_dir.rename(hidden)
        try:
            result = subprocess.run(["bash", str(self.commands)], cwd=cwd or self.root,
                                    env=env, capture_output=True,
                                    text=True, timeout=20, check=False)
        finally:
            if moved:
                hidden.rename(git_dir)
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


class SelectionTests(Fixture):  # pylint: disable=too-many-public-methods
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
        install_log = (self.artifacts / "runner/harness-install.log").read_text()
        self.assertIn(f"Expected harness revision: {self.env['EVAL_HARNESS_REVISION']}", install_log)
        self.assertIn(f"Verified harness revision: {self.env['EVAL_HARNESS_REVISION']}", install_log)
        summary = json.loads((self.artifacts / "evals-summary.json").read_text())
        self.assertIn("config-resolution.log", summary["evals"][0]["artifacts"])

    def test_literal_prefix_and_directory_boundary(self):
        for trigger in ("skills/foo", "skills/foo/"):
            entries = [runner.Eval("x.yaml", "pr", 1, 10, "", (trigger,))]
            for path in ("skills/foobar/SKILL.md", "skills/foo-2/SKILL.md"):
                with self.subTest(trigger=trigger, path=path):
                    self.assertEqual(runner.select_evals(entries, [path]), [])
            for path in ("skills/foo", "skills/foo/SKILL.md", "skills/foo/nested/file"):
                with self.subTest(trigger=trigger, path=path):
                    self.assertEqual(runner.select_evals(entries, [path]), entries)
        entries = [runner.Eval("x.yaml", "pr", 1, 10, "", ("evals.yaml",))]
        self.assertEqual(runner.select_evals(entries, ["evals.yaml.bak"]), [])
        self.assertEqual(runner.select_evals(entries, ["evals.yaml"]), entries)
        literal = runner.Eval("x.yaml", "pr", 1, 10, "", ("skills/a[1]/",))
        self.assertEqual(runner.select_evals([literal], ["skills/a1/file"]), [])
        self.assertEqual(runner.select_evals([literal], ["skills/a[1]/file"]), [literal])

    def test_periodic_and_manual_are_skipped_without_execution(self):
        self.put("setup.sh", "exit 99\n")
        for mode in ("periodic", "manual"):
            with self.subTest(mode=mode):
                entry = self.make_entry(f"evals/{mode}.yaml", run=mode, setup_script="setup.sh")
                entry.pop("triggers")
                self.write_manifest([entry])
                result = self.run_step(PULL_BASE_SHA="")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"run: {mode} is not executed", result.stdout)
                self.assertEqual(self.calls(), [])
                self.assertEqual(self.junit().attrib["tests"], "0")
                summary = json.loads((self.artifacts / "evals-summary.json").read_text())
                self.assertEqual(summary["status"], "no_evals")

    def test_mixed_modes_only_execute_pr_eval(self):
        self.put("setup.sh", "exit 99\n")
        entries = [self.entry]
        for mode in ("periodic", "manual"):
            entry = self.make_entry(f"evals/{mode}.yaml", run=mode, setup_script="setup.sh")
            entries.append(entry)
        entries[1].pop("triggers")
        self.write_manifest(entries)
        self.change_skill()
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.claude_calls()), 1)
        self.assertEqual(self.junit().attrib["tests"], "1")
        for mode in ("periodic", "manual"):
            self.assertIn(f"run: {mode} is not executed", result.stdout)

    def test_pr_entries_still_require_triggers(self):
        entry = dict(self.entry)
        entry.pop("triggers")
        self.write_manifest([entry])
        self.assertNotEqual(self.run_step().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_empty_manifest(self):
        self.write_manifest([])
        self.assertEqual(self.run_step(PULL_BASE_SHA="").returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_missing_or_invalid_job_spec_fails_before_any_calls(self):
        spec = json.loads(self.job_spec())
        refs = spec["refs"]
        for job_spec in ("", "not json", "[]", json.dumps({**spec, "type": "batch"}),
                         json.dumps({**spec, "refs": None}), json.dumps({**spec, "refs": {**refs, "pulls": []}}),
                         json.dumps({**spec, "refs": {**refs, "pulls": [{"number": PULL, "sha": "abc"}]}})):
            with self.subTest(job_spec=job_spec[:40]):
                self.calls_path.unlink(missing_ok=True)
                result = self.run_step(JOB_SPEC=job_spec)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("JOB_SPEC", result.stdout)
                self.assertEqual(self.junit().attrib["failures"], "1")
                self.assertEqual(self.calls(), [])

    def test_unreadable_pull_request_is_an_error_before_harness_or_model_calls(self):
        self.change_skill()
        self.github_fixture_override = {"pulls": {}}  # GitHub hides private repositories behind 404.
        result = self.run_step()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("HTTP 404", result.stdout)
        self.assertIn("GITHUB_TOKEN_PATH", result.stdout)
        self.assertIn("not a no-op", result.stdout)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.junit().attrib["failures"], "1")

    def test_moved_pull_request_head_is_an_error_before_harness_or_model_calls(self):
        tested = self.head()
        self.change_skill()  # GitHub now reports a newer head than the job tested.
        result = self.run_step(JOB_SPEC=self.job_spec(pulls=[{"number": PULL, "sha": tested}]))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("changed after the job started", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_retargeted_pull_request_base_is_an_error_before_harness_or_model_calls(self):
        self.change_skill()
        fixture = self.github_fixture(self.base)  # Same head the job tested, new base branch.
        fixture["pulls"][f"{ORG}/{REPO}#{PULL}"]["base_ref"] = "release-4.22"
        self.github_fixture_override = fixture
        result = self.run_step()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("retargeted after the job started", result.stdout)
        self.assertEqual(self.calls(), [])
        failure = self.junit().find("testcase/failure").attrib["message"]
        self.assertIn("retargeted after the job started", failure)

    def test_rename_and_deletion_match_original_path(self):
        self.git("mv", "skills/foo/SKILL.md", "docs/moved.md")
        self.commit()
        _, files = self.select_entries()  # A rename lists both paths, like --no-renames.
        self.assertEqual(sorted(files), ["docs/moved.md", "skills/foo/SKILL.md"])
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MATCH evals/eval-foo.yaml: 'skills/foo/SKILL.md'", result.stdout)
        shutil.rmtree(self.repo / "eval")  # Fake harness output is not part of the next commit.
        self.env["PULL_BASE_SHA"] = self.base = self.head()
        self.git("rm", "-q", "docs/moved.md")
        self.commit()
        self.assertEqual(self.select_entries()[1], ["docs/moved.md"])  # Deletions count.
        self.entry["triggers"] = ["docs/moved.md"]
        self.write_manifest([self.entry])
        self.git("add", "evals.yaml")
        self.git("commit", "-qm", "trigger on the deleted path")
        self.calls_path.unlink(missing_ok=True)
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MATCH evals/eval-foo.yaml: 'docs/moved.md'", result.stdout)
        self.assertEqual(len(self.claude_calls()), 1)

    def test_paths_with_spaces_and_newlines_survive(self):
        self.put("skills/foo/space and\nnewline.md", "test")
        self.commit()
        self.assertIn("skills/foo/space and\nnewline.md", self.select_entries()[1])

    def test_entry_point_needs_no_git_metadata(self):
        self.change_skill()
        self.github_fixture_override = self.github_fixture(self.base)
        job_spec = self.job_spec()
        shutil.rmtree(self.repo / ".git")
        result = self.run_step(JOB_SPEC=job_spec)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.claude_calls()), 1)
        self.assertFalse(any(call.startswith("unexpected-git") for call in self.calls()))

    def test_rehearsal_never_diffs_the_release_pull_request(self):
        self.change_skill()
        fixture = self.github_fixture(self.base)  # The release PR would match triggers if used.
        fixture["pulls"]["openshift/release#88000"] = {
            "head_sha": "a" * 40, "files": [{"filename": "skills/foo/SKILL.md", "status": "modified"}]}
        self.github_fixture_override = fixture
        job_spec = json.dumps({
            "type": "presubmit", "job": "rehearse-88000-pull-ci-openshift-eng-example-main-eval-runner",
            "refs": {"org": "openshift", "repo": "release", "base_ref": "main", "base_sha": "b" * 40,
                     "pulls": [{"number": 88000, "sha": "a" * 40}]},
            "extra_refs": [{"org": ORG, "repo": REPO, "base_ref": "main", "workdir": True}]})
        result = self.run_step(JOB_SPEC=job_spec)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"NO-PR: the checkout under test is {ORG}/{REPO}@main", result.stdout)
        self.assertIn("openshift/release#88000", result.stdout)
        self.assertEqual(self.github_requests(), [])
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.junit().attrib["tests"], "0")

    def batch_fixture(self, second_head="c" * 40):
        self.github_fixture_override = {"pulls": {
            f"{ORG}/{REPO}#7": {"head_sha": "b" * 40, "files": [{"filename": "docs/guide.md", "status": "modified"}]},
            f"{ORG}/{REPO}#8": {"head_sha": second_head,
                                "files": [{"filename": "skills/foo/SKILL.md", "status": "modified"}]}}}
        return self.job_spec("batch", [{"number": 7, "sha": "b" * 40}, {"number": 8, "sha": "c" * 40}])

    def test_batch_selects_the_union_of_every_pull(self):
        result = self.run_step(JOB_TYPE="batch", JOB_SPEC=self.batch_fixture())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("MATCH evals/eval-foo.yaml: 'skills/foo/SKILL.md'", result.stdout)
        self.assertEqual(len(self.claude_calls()), 1)
        listed = {request["url"].split("?")[0] for request in self.github_requests() if "/files" in request["url"]}
        self.assertEqual(listed, {f"https://api.github.com/repos/{ORG}/{REPO}/pulls/{n}/files" for n in (7, 8)})

    def test_batch_head_guard_applies_to_every_pull(self):
        result = self.run_step(JOB_TYPE="batch", JOB_SPEC=self.batch_fixture(second_head="d" * 40))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"{ORG}/{REPO}#8 head is", result.stdout)
        self.assertEqual(self.calls(), [])

    def test_token_authenticates_api_calls_and_is_never_printed(self):
        token = self.root / "github-token"
        token.write_text("test-token-value\n")
        self.put("docs/guide.md", "new docs")
        self.commit()
        result = self.run_step(GITHUB_TOKEN_PATH=str(token))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        requests = self.github_requests()
        self.assertTrue(requests)
        self.assertEqual({(request["authorization"], request["authorization_sha256"]) for request in requests},
                         {("Bearer <redacted>", hashlib.sha256(b"Bearer test-token-value").hexdigest())})
        self.assertNotIn("test-token-value", self.github_log.read_text())
        self.assertNotIn("test-token-value", result.stdout + result.stderr)
        self.assertNotIn("test-token-value", (self.artifacts / "junit_claude-eval.xml").read_text())

    def test_test_api_answers_the_harness_release_lookup(self):
        self.change_skill()  # Unscripted, the test sitecustomize passes this URL through to urllib.
        self.github_responses = {"/repos/fullsend-ai/agent-eval-harness/releases/latest": [
            {"body": {"tag_name": "v1.0.0"}}]}
        self.run_step(EVAL_HARNESS_REVISION="")
        install_log = (self.artifacts / "runner/harness-install.log").read_text()
        self.assertIn("Expected harness revision: v1.0.0 (latest release)", install_log)
        self.assertIn("https://api.github.com/repos/fullsend-ai/agent-eval-harness/releases/latest",
                      [request["url"] for request in self.github_requests()])

    def test_manifest_without_pr_entries_makes_no_api_calls(self):
        self.write_manifest([])
        self.assertEqual(self.run_step(JOB_SPEC="").returncode, 0)
        self.assertEqual(self.github_requests(), [])

    def test_manifest_edit_is_explicitly_triggered(self):
        self.entry["triggers"].append("evals.yaml")
        self.write_manifest([self.entry])
        self.commit()
        self.assertEqual(self.run_step().returncode, 0)
        self.assertEqual(len(self.claude_calls()), 1)

    def test_workdir_without_manifest_is_failure_not_noop(self):
        result = self.run_step(EVAL_WORKDIR=str(self.repo / "skills"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])


class CaseSelectionTests(Fixture):
    def setUp(self):
        super().setUp()
        self.enable_case_subsets()

    def test_sibling_trigger_path_does_not_expand_case_subset(self):
        self.entry["triggers"] = ["skills/foo", "evals/cases/foo"]
        self.write_manifest([self.entry])
        entry, = runner.load_manifest(self.repo)
        files = ["evals/cases/foo/case-001/input.yaml", "skills/foo-2/SKILL.md",
                 "evals/cases/foo-2/case-002/input.yaml"]
        self.assertEqual(runner.select_evals([entry], files), [entry])
        self.assertEqual(runner.select_cases(self.repo, entry, files), ("case-001",))

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

    def test_changed_base_or_intermediate_config_invalidates_case_subset(self):
        self.put("evals/base.yaml", "models: {skill: base}\n")
        self.put("evals/profiles/ci.yaml", "extends: ../base.yaml\n")
        entry = runner.load_manifest(self.repo)[0]
        chain = ("evals/base.yaml", "evals/profiles/ci.yaml", entry.config)
        for changed in chain[:2]:
            with self.subTest(changed=changed):
                files = ["evals/cases/foo/case-001/input.yaml", changed]
                self.assertIsNone(runner.select_cases(self.repo, entry, files, chain))

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

    def test_base_config_change_outside_triggers_does_not_select_eval(self):
        self.put("evals/base.yaml", "models: {skill: model}\n")
        self.put(self.entry["config"], "extends: base.yaml\n")
        self.entry["triggers"] = ["skills/foo/"]
        self.write_manifest([self.entry])
        self.commit()
        base = self.git("rev-parse", "HEAD").strip()
        self.put("evals/base.yaml", "models: {skill: changed-model}\n")
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
        self.assertIn("same directory as the harness-resolved dataset.path", result.stdout)
        self.assertEqual(self.claude_calls(), [])

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

    def test_physical_copy_under_the_guessed_name_is_ignored(self):
        self.change_skill()  # release#85928: the orchestrator duplicated the run with cp -r.
        result = self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: "copied_run"}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("run=example:foo/", result.stdout)
        log = (self.eval_artifacts() / "regression.log").read_text()
        self.assertTrue("/example:foo/" in log and "/config-name/" not in log)
        self.assertEqual(self.junit().attrib["failures"], "0")

    def test_run_written_only_under_the_guessed_name_fails_with_a_hint(self):
        self.change_skill()
        result = self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: "wrong_name_only"}))
        self.assertNotEqual(result.returncode, 0)
        for text in ("example:foo/", "other directories named", "config-name/", "STRAY"):
            self.assertIn(text, result.stdout)
        self.assertEqual(self.junit().attrib["failures"], "1")
        with tarfile.open(self.eval_artifacts() / "stray-runs.tar") as archive:
            self.assertTrue(any(n.startswith("config-name/") and n.endswith("/summary.yaml") for n in archive.getnames()))
        self.assertFalse((self.eval_artifacts() / "eval-run.tar").exists() or (self.eval_artifacts() / "summary.yaml").exists())
        summary = json.loads((self.artifacts / "evals-summary.json").read_text())["evals"][0]
        self.assertEqual((summary["status"], "stray-runs.tar" in summary["artifacts"]), ("failed", True))

    def test_exact_directory_lookup(self):
        runs = self.repo / "eval/runs"
        physical = runs / "physical" / "current-run"
        physical.mkdir(parents=True)
        (runs / "other" / "current-run").mkdir(parents=True)
        with self.assertRaisesRegex(runner.EvalError, r"skill/current-run not found.*other/current-run"):
            runner.run_directory(runs, "current-run", "skill")  # Strays are listed, never used.
        (runs / "skill").mkdir()
        link = runs / "skill" / "current-run"
        link.symlink_to(physical, target_is_directory=True)
        self.assertEqual(runner.run_directory(runs, "current-run", "skill"), physical.resolve())
        link.unlink()
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(runner.EvalError, "escapes the runs directory"):
            runner.run_directory(runs, "current-run", "skill")


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
        entries, files = self.select_entries()
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
            self.assertEqual(runner.run_evals(self.repo, entries, files, self.artifacts, env), 1)
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
                                env={**self.step_env(), "TMPDIR": str(bundle_tmp)},
                                capture_output=True, text=True, timeout=20, check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.claude_calls()), 1)
        self.assertEqual(list(bundle_tmp.iterdir()), [])

    def test_termination_reaches_python_and_preserves_junit(self):
        self.change_skill()
        ready = self.root / "ready"
        bundle_tmp = self.root / "bundles"
        bundle_tmp.mkdir()
        env = {**self.step_env(), "WAIT_READY": str(ready), "TMPDIR": str(bundle_tmp)}
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
        result = self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: "threshold_failure"}))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("harness regression check failed", result.stdout)
        self.assertEqual(self.junit().attrib["failures"], "1")
        self.assertIn("REGRESSIONS: 1", (self.eval_artifacts() / "regression.log").read_text())

    def test_regression_uses_actual_run_after_orchestrator_removes_alias(self):
        self.change_skill()
        result = self.run_step(BEHAVIORS=json.dumps({self.entry["config"]: "removed_alias"}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.repo / "eval/runs/config-name").exists())
        log = (self.eval_artifacts() / "regression.log").read_text()
        self.assertIn("/example:foo/", log)
        self.assertIn("REGRESSIONS: 0", log)
        self.assertEqual(self.junit().attrib["failures"], "0")

    def test_missing_thresholded_judge_is_failure(self):
        self.put(self.entry["config"], "models: {skill: model}\ndataset: {path: cases/eval-foo}\nthresholds: {missing: {min_mean: 1}}")
        self.change_skill()
        self.assertNotEqual(self.run_step().returncode, 0)
        self.assertIn("missing thresholded judge", self.last_result.stdout)

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
        entries, files = self.select_entries()
        with mock.patch.object(runner, "STEP_TIMEOUT", -1), mock.patch.object(runner, "command", return_value=0):
            self.assertEqual(runner.run_evals(self.repo, entries, files, self.artifacts, self.env), 1)
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
