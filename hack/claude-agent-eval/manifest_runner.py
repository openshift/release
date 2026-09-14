#!/usr/bin/env python3
"""PR eval selection and orchestration for openshift-claude-agent-eval.

The step embeds this file with sync_commands.py because Prow distributes the
commands script, not sibling Python files. Only PyYAML and the stdlib are needed.
"""

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET
from dataclasses import dataclass

import yaml


MANIFEST = "evals.yaml"
STEP_TIMEOUT = 13800  # Leave ten minutes inside the Prow step's four-hour limit.
EVAL_TIMEOUT = 12600


class EvalError(Exception):
    """An invalid configuration or unsuccessful evaluation."""


class Interrupted(BaseException):
    """Stop scheduling evals when Prow terminates the step."""


class UniqueKeyLoader(yaml.SafeLoader):  # pylint: disable=too-many-ancestors
    """Do not silently accept a duplicate manifest setting."""


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str) or key in result:
            raise EvalError("manifest keys must be unique strings")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


@dataclass(frozen=True)
class Eval:
    config: str
    run: str
    parallelism: int
    max_turns: int
    setup_script: str
    triggers: tuple
    eval_cases_dir: str = ""

    @property
    def artifact_name(self):
        # A basename is readable; a path hash also distinguishes equal basenames
        # in different plugins (and paths that sanitize to the same filename).
        stem = re.sub(r"[^a-zA-Z0-9_-]", "-", Path(self.config).stem)[:80]
        suffix = hashlib.sha256(self.config.encode()).hexdigest()[:12]
        return f"{stem}-{suffix}"


def relative_path(value, field):
    if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
        raise EvalError(f"{field} must be a nonempty relative path")
    if (value.startswith("/") or "\\" in value
            or any(p in ("", ".", "..") for p in value.rstrip("/").split("/"))):
        raise EvalError(f"{field} must be a normalized repository-relative path: {value!r}")
    return value


def repo_file(repo, value, field):
    relative_path(value, field)
    path = (repo / value).resolve()
    if not path.is_relative_to(repo) or not path.is_file():
        raise EvalError(f"{field} must reference an existing file inside the repository: {value}")
    return path


def repo_directory(repo, value, field):
    relative_path(value, field)
    path = (repo / value).resolve()
    if not path.is_relative_to(repo) or not path.is_dir():
        raise EvalError(f"{field} must reference an existing directory inside the repository: {value}")
    return path


def load_manifest(repo):
    try:
        with repo_file(repo, MANIFEST, "manifest").open(encoding="utf-8") as stream:
            document = yaml.load(stream, Loader=UniqueKeyLoader)
    except (OSError, yaml.YAMLError) as error:
        raise EvalError(f"cannot read {MANIFEST}: {error}") from error
    if not isinstance(document, dict) or set(document) != {"evals"}:
        raise EvalError("manifest must be a mapping containing only 'evals'")
    if not isinstance(document["evals"], list):
        raise EvalError("evals must be a list (use evals: [] for an empty manifest)")
    entries, seen = [], set()
    fields = {"config", "run", "parallelism", "max_turns", "setup_script", "triggers", "eval_cases_dir"}
    required = {"config", "run", "parallelism", "max_turns"}
    for index, entry in enumerate(document["evals"]):
        label = f"evals[{index}]"
        if not isinstance(entry, dict) or not required <= entry.keys() or entry.keys() - fields:
            raise EvalError(f"{label}: expected {sorted(required)}; optional: setup_script, triggers, eval_cases_dir")
        config = entry["config"]
        repo_file(repo, config, f"{label}.config")
        if PurePosixPath(config).suffix not in (".yaml", ".yml") or config in seen:
            raise EvalError(f"{label}.config must be a unique YAML config path")
        seen.add(config)
        if entry["run"] not in ("pr", "periodic", "manual"):
            raise EvalError(f"{label}.run must be pr, periodic, or manual")
        for field in ("parallelism", "max_turns"):
            if (not isinstance(entry[field], int) or isinstance(entry[field], bool)
                    or entry[field] <= 0):
                raise EvalError(f"{label}.{field} must be a positive integer")
        setup = entry.get("setup_script", "")
        if "setup_script" in entry:
            repo_file(repo, setup, f"{label}.setup_script")
        cases_dir = entry.get("eval_cases_dir", "")
        if "eval_cases_dir" in entry:
            repo_directory(repo, cases_dir, f"{label}.eval_cases_dir")
        triggers = entry.get("triggers", [])
        if not isinstance(triggers, list) or (entry["run"] == "pr" and not triggers):
            raise EvalError(f"{label}.triggers must be a list, nonempty for run: pr")
        for trigger in triggers:
            relative_path(trigger, f"{label}.triggers")
        entries.append(Eval(config, entry["run"], entry["parallelism"],
                            entry["max_turns"], setup, tuple(triggers), cases_dir))
    return entries


def changed_files(repo, base_sha):
    if not re.fullmatch(r"[0-9a-fA-F]{7,64}", base_sha):
        raise EvalError("PR manifest mode requires PULL_BASE_SHA containing a Git commit SHA")
    try:
        root = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=repo,
                              check=True, capture_output=True, text=True).stdout.strip()
        if Path(root).resolve() != repo:
            raise EvalError("EVAL_WORKDIR must be the root of the PR Git checkout")
        # --no-renames includes both old and new paths, so a move out of a
        # triggered directory still selects its eval. -z preserves odd filenames.
        diff = subprocess.run(
            ["git", "diff", "--name-only", "-z", "--no-renames", f"{base_sha}...HEAD", "--"],
            cwd=repo, check=True, capture_output=True).stdout
    except subprocess.CalledProcessError as error:
        raise EvalError("cannot compute PR changes; ensure the checkout includes PULL_BASE_SHA "
                        "and its merge base (a diff failure is not a no-op)") from error
    return [os.fsdecode(path) for path in diff.split(b"\0") if path]


def select_evals(entries, files):
    selected = []
    for entry in entries:
        if entry.run != "pr":
            print(f"SKIP {entry.config}: run: {entry.run} is not enabled in PR mode", flush=True)
            continue
        match = next((path for path in files if path.startswith(entry.triggers)), None)
        if match is None:
            print(f"SKIP {entry.config}: no changed file matches triggers {entry.triggers}", flush=True)
        else:
            print(f"MATCH {entry.config}: {match!r}", flush=True)
            selected.append(entry)
    return selected


def select_cases(repo, entry, files):
    """Return exact changed case IDs, or None to run the full dataset.

    This policy is deliberately separate from eval trigger matching: adding a
    case directory does not enroll new triggers. Prefer a full run whenever a
    relevant change cannot be attributed to a surviving case directory.
    """
    reason = "eval_cases_dir is not set"
    if entry.eval_cases_dir:
        prefix = entry.eval_cases_dir.rstrip("/") + "/"
        # Config/setup/manifest changes invalidate a subset even when omitted
        # from triggers. They do not independently select an otherwise skipped eval.
        controls = {MANIFEST, entry.config, entry.setup_script}
        relevant = [path for path in files if path.startswith(entry.triggers)
                    or path.startswith(prefix) or path in controls]
        reason = "no attributable case changes"
        case_ids = set()
        for path in relevant:
            if path in controls or not path.startswith(prefix):
                reason = f"change outside individual cases: {path!r}"
                break
            case_id, separator, _ = path[len(prefix):].partition("/")
            case_path = (repo / entry.eval_cases_dir / case_id).resolve()
            if (not separator or case_id.startswith("-") or not case_path.is_dir()):
                reason = f"shared file, removed case, or ambiguous case path: {path!r}"
                break
            if not case_path.is_relative_to((repo / entry.eval_cases_dir).resolve()):
                raise EvalError(f"case directory escapes eval_cases_dir: {path!r}")
            case_ids.add(case_id)
        else:
            if case_ids:
                cases = tuple(sorted(case_ids))
                print(f"CASES {entry.config}: changed cases {cases!r}", flush=True)
                return cases
    print(f"CASES {entry.config}: full dataset ({reason})", flush=True)
    return None


def read_eval(repo, entry):
    try:
        with repo_file(repo, entry.config, "config").open(encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
    except (OSError, yaml.YAMLError) as error:
        raise EvalError(f"cannot read {entry.config}: {error}") from error
    models = config.get("models") if isinstance(config, dict) else None
    model = models.get("skill") if isinstance(models, dict) else None
    if not isinstance(model, str) or not model.strip():
        raise EvalError(f"{entry.config}: models.skill is required; EVAL_MODEL is ignored")
    if entry.eval_cases_dir:
        dataset = config.get("dataset")
        dataset_path = dataset.get("path") if isinstance(dataset, dict) else None
        # The harness resolves dataset.path against the eval config directory.
        # Check consistency without rewriting the config or overriding its dataset.
        if (not isinstance(dataset_path, str) or not dataset_path
                or (repo / entry.config).resolve().parent.joinpath(dataset_path).resolve()
                != (repo / entry.eval_cases_dir).resolve()):
            raise EvalError(f"{entry.config}: eval_cases_dir must point to the same directory "
                            "as dataset.path (resolved relative to the eval YAML)")
    return config, model


def command(args, repo, env, log, timeout, *, stdout=None):  # pylint: disable=too-many-arguments
    """Run a bounded command and terminate its entire process group on failure."""
    with log.open("wb") as output:
        with subprocess.Popen(args, cwd=repo, env=env, stdin=subprocess.DEVNULL,
                              stdout=stdout if stdout is not None else output, stderr=output,
                              start_new_session=True) as process:
            try:
                return process.wait(timeout=max(0.01, timeout))
            except BaseException:
                # Popen's timeout kills only the immediate child; Claude and
                # setup scripts can have their own descendants.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                raise


def write_junit(artifacts, results):
    suite = ET.Element("testsuite", name="claude-eval", tests=str(len(results)),
                       failures=str(sum(bool(r[2]) for r in results)),
                       time=f"{sum(r[1] for r in results):.3f}")
    for name, duration, failure in results:
        case = ET.SubElement(suite, "testcase", name=f"[sig-claude] {name} evaluation",
                             time=f"{duration:.3f}")
        if failure:
            ET.SubElement(case, "failure", message=failure).text = failure
    destination = artifacts / "junit_claude-eval.xml"
    temporary = destination.with_suffix(".tmp")
    ET.ElementTree(suite).write(temporary, encoding="utf-8", xml_declaration=True)
    temporary.replace(destination)


def run_directory(runs, run_id):
    # The harness owns the eval-name directory (it need not equal the filename).
    matches = [p for p in runs.glob(f"*/{run_id}") if p.is_dir()]
    if (runs / run_id).is_dir():  # Also support the older flat harness layout.
        matches.append(runs / run_id)
    if len(matches) != 1:
        raise EvalError(f"expected exactly one harness run directory for {run_id}, found {len(matches)}")
    return matches[0]


def collect_result(runs, run_id, name, artifacts):
    directory = run_directory(runs, run_id)
    for filename, suffix in (("summary.yaml", "summary.yaml"),
                             ("report.html", "report-summary.html"),
                             ("run_result.json", "run_result.json")):
        source = directory / filename
        if source.is_file():
            (artifacts / f"{name}-{suffix}").write_bytes(source.read_bytes())
    return directory


def verify_result(directory, config):
    try:
        result = json.loads((directory / "run_result.json").read_text(encoding="utf-8"))
        summary = yaml.safe_load((directory / "summary.yaml").read_text(encoding="utf-8"))
    except (OSError, ValueError, yaml.YAMLError) as error:
        raise EvalError(f"missing or invalid harness results: {error}") from error
    if (not isinstance(result, dict) or not isinstance(result.get("exit_code"), int)
            or isinstance(result["exit_code"], bool) or result["exit_code"] != 0):
        raise EvalError("harness execution failed or did not report an exit_code")
    if not isinstance(summary, dict) or not isinstance(summary.get("judges"), dict):
        raise EvalError("harness did not produce a judges summary")
    if not (directory / "report.html").is_file():
        raise EvalError("harness did not produce report.html")
    # score.py regression currently ignores a completely absent judge. Treat
    # missing thresholded judges as incomplete; let the harness interpret limits.
    for judge in config.get("thresholds", {}):
        if judge not in summary["judges"]:
            raise EvalError(f"missing thresholded judge in summary: {judge}")


def archive(runs, artifacts, env):
    sources = [(runs, "eval-runs.tar.gz", "eval/runs")]
    sessions = Path(env.get("CLAUDE_CONFIG_DIR", "/home/claude/.claude")) / "projects"
    sources.append((sessions, "claude-sessions.tar.gz", "projects"))
    for source, filename, arcname in sources:
        if source.is_dir():
            with tarfile.open(artifacts / filename, "w:gz") as output:
                output.add(source, arcname=arcname)


def emit_metrics(env, repo, artifacts, *, stream_log, result, run_id, prompt):  # pylint: disable=too-many-arguments
    # Reuse the existing step's AutoDL implementation, including its aggregation
    # across orchestrator/case models. The entry point exports this function.
    if "BASH_FUNC_write_eval_metrics%%" not in env:
        print("WARNING: metrics bridge unavailable outside the Prow step", flush=True)
        return
    try:
        status = command(["bash", "-c", 'write_eval_metrics "$@"', "eval-metrics",
                          str(stream_log), str(result) if result else "", run_id, prompt],
                         repo, env, artifacts / f"{run_id}-metrics.log", 60)
        if status:
            print(f"WARNING: metrics extraction failed for {run_id}", flush=True)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"WARNING: metrics extraction failed: {error}", flush=True)


def run_evals(repo, entries, artifacts, env, files=()):  # pylint: disable=too-many-statements
    results = []
    started = time.monotonic()
    runs = Path(env.get("AGENT_EVAL_RUNS_DIR") or "eval/runs")
    if not runs.is_absolute():
        runs = repo / runs
    runs = runs.resolve()
    child_env = env.copy()
    child_env.pop("BASH_FUNC_write_eval_metrics%%", None)
    child_env.pop("EVAL_SNAPSHOT_DIR", None)
    child_env["AGENT_EVAL_RUNS_DIR"] = str(runs)
    child_env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-cli"

    def remaining():
        return STEP_TIMEOUT - (time.monotonic() - started)

    try:
        # Validate every selected eval before installing anything or calling Claude.
        configs = [read_eval(repo, entry) for entry in entries]
        case_filters = [select_cases(repo, entry, files) for entry in entries]
        token_path = Path(env.get("GITHUB_TOKEN_PATH") or "/nonexistent")
        if token_path.is_file():
            child_env["GITHUB_TOKEN"] = token_path.read_text(encoding="utf-8").strip()
        with tempfile.TemporaryDirectory(prefix="agent-eval-harness-") as temporary:
            harness = Path(temporary) / "plugin"
            status = command(["git", "clone", "--depth", "1",
                              "https://github.com/opendatahub-io/agent-eval-harness.git", str(harness)],
                             repo, child_env, artifacts / "harness-install.log", min(300, remaining()))
            if status:
                raise EvalError("cannot clone agent-eval-harness; see harness-install.log")
            child_env["PYTHONPATH"] = os.pathsep.join(
                [str(harness), str(repo), child_env.get("PYTHONPATH", "")])
            for entry, (config, model), cases in zip(entries, configs, case_filters):
                name = entry.artifact_name
                run_id = f"ci-{name}-{uuid.uuid4().hex[:12]}"
                run_env = child_env.copy()
                begin = time.monotonic()
                failure = ""
                invoked = False
                directory = None
                stream_log = artifacts / f"claude-eval-{name}.log"
                args = ["--config", entry.config, "--model", model,
                        "--run-id", run_id, "--parallelism", str(entry.parallelism)]
                if cases:
                    args.extend(["--cases", *cases])
                prompt = "/eval-run " + shlex.join(args)
                print(f"RUN {entry.config}: model={model}, parallelism={entry.parallelism}, "
                      f"orchestrator max_turns={entry.max_turns}", flush=True)
                try:
                    if remaining() <= 0:
                        raise EvalError("step time limit reached before this eval could start")
                    if entry.setup_script:
                        setup_log = artifacts / f"{name}-setup.log"
                        # Keep stdout separate: existing setup scripts return the
                        # fixture directory on stdout and write diagnostics to stderr.
                        with tempfile.TemporaryFile() as output:
                            status = command(["bash", entry.setup_script], repo, run_env, setup_log,
                                             remaining(), stdout=output)
                            if status:
                                raise EvalError(f"setup_script failed (exit {status}); see {setup_log.name}")
                            output.seek(0)
                            run_env["EVAL_SNAPSHOT_DIR"] = output.read().decode().rstrip("\n")
                    if remaining() <= 0:
                        raise EvalError("step time limit reached during setup")
                    invoked = True
                    status = command(["claude", "--model", env.get("CLAUDE_MODEL", "claude-opus-4-6"),
                                      "--plugin-dir", str(harness), "--allowedTools",
                                      "Bash Read Write Edit Grep Glob Agent Skill",
                                      "--output-format", "stream-json", "--max-turns", str(entry.max_turns),
                                      "-p", prompt, "--verbose"], repo, run_env, stream_log,
                                     min(EVAL_TIMEOUT, remaining()))
                    if status:
                        raise EvalError(f"Claude orchestrator failed (exit {status}); see {stream_log.name}")
                    directory = collect_result(runs, run_id, name, artifacts)
                    verify_result(directory, config)
                    # Deterministic threshold check using the harness itself: do
                    # not trust an outer Claude exit code as the eval verdict.
                    status = command([sys.executable, str(harness / "skills/eval-run/scripts/score.py"),
                                      "regression", "--config", entry.config, "--run-id", run_id],
                                     repo, run_env, artifacts / f"{name}-regression.log", min(60, remaining()))
                    if status:
                        raise EvalError("harness regression check failed; see regression log")
                except (EvalError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                    failure = str(error)
                except Interrupted as error:
                    failure = str(error)
                    raise
                finally:
                    if invoked:
                        try:
                            directory = collect_result(runs, run_id, name, artifacts)
                        except (EvalError, OSError) as error:
                            failure = failure or str(error)
                        emit_metrics(env, repo, artifacts, stream_log=stream_log,
                                     result=directory / "run_result.json" if directory else None,
                                     run_id=run_id, prompt=prompt)
                    results.append((entry.config, time.monotonic() - begin, failure))
                    write_junit(artifacts, results)
                print(f"{'FAIL' if failure else 'PASS'} {entry.config}: {failure or 'complete'}", flush=True)
    except (EvalError, Interrupted, OSError, ValueError, subprocess.TimeoutExpired) as error:
        results.append(("manifest runner", time.monotonic() - started, str(error)))
        print(f"ERROR: {error}", flush=True)
    finally:
        try:
            archive(runs, artifacts, env)
        except (OSError, tarfile.TarError) as error:
            results.append(("artifact archive", 0, str(error)))
        write_junit(artifacts, results)
    return int(any(result[2] for result in results))


def interrupted(signum, _frame):
    raise Interrupted(f"interrupted by signal {signum}")


def main():
    env = dict(os.environ)
    repo = Path(env.get("EVAL_WORKDIR") or "/opt/ai-helpers").resolve()
    artifacts = Path(env["ARTIFACT_DIR"]).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    env["ARTIFACT_DIR"] = str(artifacts)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        if env.get("EVAL_DISCOVER") or env.get("EVAL_CONFIG", "eval.yaml") not in ("", "eval.yaml"):
            raise EvalError("EVAL_MANIFEST is mutually exclusive with EVAL_DISCOVER and explicit EVAL_CONFIG")
        if env.get("EVAL_EXTRA_ARGS"):
            raise EvalError("EVAL_EXTRA_ARGS is not supported in manifest mode; settings belong in the manifest/eval YAML")
        if env.get("JOB_TYPE", "presubmit") != "presubmit":
            raise EvalError("manifest mode currently supports PR runs only (periodic/manual are follow-on work)")
        entries = load_manifest(repo)
        files = changed_files(repo, env.get("PULL_BASE_SHA", "")) if any(e.run == "pr" for e in entries) else []
        selected = select_evals(entries, files)
        if not selected:
            print("No evals matched; exiting without setup, harness installation, or Claude calls.", flush=True)
            write_junit(artifacts, [])
            return 0
    except (EvalError, Interrupted, OSError) as error:
        print(f"ERROR: {error}", flush=True)
        write_junit(artifacts, [("manifest selection", 0, str(error))])
        return 1
    return run_evals(repo, selected, artifacts, env, files)


if __name__ == "__main__":
    sys.exit(main())
