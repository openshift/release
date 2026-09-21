#!/usr/bin/env python3
"""Run PR evaluations selected by the repository's manifest.

The step bundles this file with sync_commands.py because ci-operator distributes
the commands file, not sibling Python files. Only PyYAML and the stdlib are needed.
"""

import json
from html import escape
import os
from pathlib import Path, PurePosixPath
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
from urllib.parse import quote

import yaml

try:  # Package imports for repository tooling; direct imports for the CI bundle.
    from .eval_plan import EvalError, EvalPlan, changed_files, read_config, relative_path, repo_directory, repo_file
except ImportError:
    from eval_plan import EvalError, EvalPlan, changed_files, read_config, relative_path, repo_directory, repo_file


MANIFEST = "evals.yaml"
STEP_TIMEOUT = 13800  # Leave ten minutes inside the Prow step's four-hour limit.
EVAL_TIMEOUT = 12600


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
        if entry["run"] != "pr":
            raise EvalError(f"{label}.run must be pr; periodic/manual evals are not supported")
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
        if not isinstance(triggers, list) or not triggers:
            raise EvalError(f"{label}.triggers must be a nonempty list")
        for trigger in triggers:
            relative_path(trigger, f"{label}.triggers")
        entries.append(Eval(config, entry["run"], entry["parallelism"],
                            entry["max_turns"], setup, tuple(triggers), cases_dir))
    return entries


def select_evals(entries, files):
    selected = []
    for entry in entries:
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
    config = read_config(repo_file(repo, entry.config, "config"))
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
    # A harness invocation can expose the same run through an eval/skill alias.
    # Count physical directories, and archive their contents rather than a link.
    directories = {path.resolve() for path in matches}
    if any(not path.is_relative_to(runs.resolve()) for path in directories):
        raise EvalError(f"harness run directory for {run_id} escapes the runs directory")
    if len(directories) != 1:
        raise EvalError(f"expected exactly one harness run directory for {run_id}, found {len(directories)}")
    return directories.pop()


def collect_result(directory, artifacts):
    errors = []
    for filename, suffix in (("summary.yaml", "summary.yaml"),
                             ("report.html", "report-summary.html"),
                             ("run_result.json", "run_result.json")):
        source = directory / filename
        try:
            if source.is_file():
                (artifacts / suffix).write_bytes(source.read_bytes())
        except OSError as error:
            errors.append(f"cannot collect {filename}: {error}")
    if errors:
        raise EvalError("; ".join(errors))


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


def archive(directory, artifacts):
    destination = artifacts / "eval-run.tar.gz"
    temporary = destination.with_suffix(".tmp")
    try:
        with tarfile.open(temporary, "w:gz") as output:
            output.add(directory, arcname="run")
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def write_index(artifacts, entries, errors):
    """Write a small index linking only artifacts that actually exist."""
    rows = []
    filenames = ("report-summary.html", "summary.yaml", "run_result.json", "claude-eval.log",
                 "setup.log", "regression.log", "metrics.log", "eval-run.tar.gz")
    for entry in entries:
        relative = Path("evals") / entry["name"]
        links = []
        if (artifacts / relative).is_dir():
            links.append(f'<a href="{quote(relative.as_posix())}/">All artifacts</a>')
        for filename in filenames:
            path = relative / filename
            if (artifacts / path).is_file():
                links.append(f'<a href="{quote(path.as_posix())}">{filename}</a>')
        cells = [escape(str(entry[key])) for key in ("config", "run_id", "status", "failure")]
        rows.append("<tr>" + "".join(f"<td>{cell}</td>" for cell in cells)
                    + f'<td>{" | ".join(links)}</td></tr>')
    errors_html = "".join(f"<li>{escape(error)}</li>" for error in errors)
    install_log = artifacts / "runner/harness-install.log"
    install_link = ('<p><a href="runner/harness-install.log">Harness installation log</a></p>'
                    if install_log.is_file() else "")
    table = ("<table><thead><tr><th>Eval config</th><th>Run ID</th><th>Status</th>"
             "<th>Failure</th><th>Artifacts</th></tr></thead><tbody>"
             + "".join(rows) + "</tbody></table>" if rows else "<p>No evaluations selected.</p>")
    document = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
                '<title>Eval results</title></head><body><h1>Eval results</h1>'
                + (f"<ul>{errors_html}</ul>" if errors else "")
                + install_link + table + "</body></html>\n")
    destination = artifacts / "evals-summary.html"
    temporary = destination.with_suffix(".tmp")
    temporary.write_text(document, encoding="utf-8")
    temporary.replace(destination)


def write_reports(artifacts, results, entries, errors):
    """Try both reports even when one output cannot be written."""
    for label, writer, args in (("index", write_index, (artifacts, entries, errors)),
                                ("JUnit", write_junit, (artifacts, results))):
        try:
            writer(*args)
        except OSError as error:
            message = f"cannot write {label}: {error}"
            if message not in errors:
                errors.append(message)
                results.append(("artifact reporting", 0, message))
            print(f"ERROR: {message}", flush=True)


def emit_metrics(env, repo, artifacts, eval_artifacts, *, stream_log, result, run_id, prompt):  # pylint: disable=too-many-arguments
    # Keep accounting bounded and non-fatal, including for incomplete eval runs.
    try:
        status = command([sys.executable, str(Path(__file__).with_name("eval_metrics.py")),
                          "/opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py",
                          str(stream_log), str(result) if result else "",
                          str(artifacts / "claude-session-metrics-autodl.json"),
                          env.get("BUILD_ID", "unknown"), run_id, prompt],
                         repo, env, eval_artifacts / "metrics.log", 60)
        if status:
            print(f"WARNING: metrics extraction failed for {run_id}", flush=True)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"WARNING: metrics extraction failed: {error}", flush=True)


def run_evals(repo, entries, artifacts, env):  # pylint: disable=too-many-statements
    results, errors = [], []
    index = [{"config": entry.config, "name": entry.artifact_name,
              "run_id": "", "status": "not run", "failure": ""} for entry in entries]
    started = time.monotonic()
    runs = Path(env.get("AGENT_EVAL_RUNS_DIR") or "eval/runs")
    if not runs.is_absolute():
        runs = repo / runs
    runs = runs.resolve()
    child_env = env.copy()
    child_env.pop("EVAL_SNAPSHOT_DIR", None)
    child_env["AGENT_EVAL_RUNS_DIR"] = str(runs)
    child_env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-cli"

    def remaining():
        return STEP_TIMEOUT - (time.monotonic() - started)

    try:
        write_reports(artifacts, results, index, errors)
        runner_artifacts = artifacts / "runner"
        runner_artifacts.mkdir(exist_ok=True)
        token_path = Path(env.get("GITHUB_TOKEN_PATH") or "/nonexistent")
        if token_path.is_file():
            child_env["GITHUB_TOKEN"] = token_path.read_text(encoding="utf-8").strip()
        with tempfile.TemporaryDirectory(prefix="agent-eval-harness-") as temporary:
            harness = Path(temporary) / "plugin"
            status = command(["git", "clone", "--depth", "1",
                              "https://github.com/opendatahub-io/agent-eval-harness.git", str(harness)],
                             repo, child_env, runner_artifacts / "harness-install.log", min(300, remaining()))
            if status:
                raise EvalError("cannot clone agent-eval-harness; see runner/harness-install.log")
            child_env["PYTHONPATH"] = os.pathsep.join(
                [str(harness), str(repo), child_env.get("PYTHONPATH", "")])
            for entry, record in zip(entries, index):
                config, model, cases = entry.settings, entry.model, entry.cases
                name = entry.artifact_name
                run_id = f"ci-{name}-{uuid.uuid4().hex[:12]}"
                record["run_id"] = run_id
                eval_artifacts = artifacts / "evals" / name
                run_env = child_env.copy()
                run_env["ARTIFACT_DIR"] = str(eval_artifacts)
                begin = time.monotonic()
                failures = []
                invoked = False
                directory = None
                stream_log = eval_artifacts / "claude-eval.log"
                args = ["--config", entry.config, "--model", model,
                        "--run-id", run_id, "--parallelism", str(entry.parallelism)]
                if cases:
                    args.extend(["--cases", *cases])
                prompt = "/eval-run " + shlex.join(args)
                print(f"RUN {entry.config}: model={model}, parallelism={entry.parallelism}, "
                      f"orchestrator max_turns={entry.max_turns}", flush=True)
                try:
                    eval_artifacts.mkdir(parents=True, exist_ok=True)
                    if remaining() <= 0:
                        raise EvalError("step time limit reached before this eval could start")
                    if entry.setup_script:
                        setup_log = eval_artifacts / "setup.log"
                        with tempfile.TemporaryFile() as output:
                            status = command(["bash", entry.setup_script], repo, run_env, setup_log,
                                             remaining(), stdout=output)
                            output.seek(0)
                            snapshot = output.read().decode().rstrip("\n")
                        if status:
                            raise EvalError(f"setup_script failed (exit {status}); see {setup_log.name}")
                        run_env["EVAL_SNAPSHOT_DIR"] = snapshot
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
                    directory = run_directory(runs, run_id)
                    verify_result(directory, config)
                    # Deterministic threshold check using the harness itself: do
                    # not trust an outer Claude exit code as the eval verdict.
                    status = command([sys.executable, str(harness / "skills/eval-run/scripts/score.py"),
                                      "regression", "--config", entry.config, "--run-id", run_id],
                                     repo, run_env, eval_artifacts / "regression.log", min(60, remaining()))
                    if status:
                        raise EvalError("harness regression check failed; see regression log")
                except (EvalError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                    failures.append(str(error))
                except Interrupted as error:
                    failures.append(str(error))
                    raise
                finally:
                    if invoked:
                        directory = None
                        try:
                            directory = run_directory(runs, run_id)
                        except (EvalError, OSError) as error:
                            failures.append(str(error))
                        if directory is not None:
                            for label, action in (("collect results", collect_result), ("archive run", archive)):
                                try:
                                    action(directory, eval_artifacts)
                                except (EvalError, OSError, tarfile.TarError) as error:
                                    failures.append(f"{label}: {error}")
                        emit_metrics(env, repo, artifacts, eval_artifacts, stream_log=stream_log,
                                     result=directory / "run_result.json" if directory else None,
                                     run_id=run_id, prompt=prompt)
                    failure = "; ".join(dict.fromkeys(failures))
                    record.update(status="failed" if failure else "passed", failure=failure)
                    results.append((entry.config, time.monotonic() - begin, failure))
                    write_reports(artifacts, results, index, errors)
                print(f"{'FAIL' if failure else 'PASS'} {entry.config}: {failure or 'complete'}", flush=True)
    except (EvalError, Interrupted, OSError, ValueError, subprocess.TimeoutExpired) as error:
        errors.append(str(error))
        results.append(("eval runner", time.monotonic() - started, str(error)))
        print(f"ERROR: {error}", flush=True)
    finally:
        write_reports(artifacts, results, index, errors)
    return int(any(result[2] for result in results))


def interrupted(signum, _frame):
    raise Interrupted(f"interrupted by signal {signum}")


def manifest_plans(repo, env):
    """Validate and select manifest inputs before execution."""
    if env.get("EVAL_DISCOVER") or env.get("EVAL_CONFIG", "eval.yaml") not in ("", "eval.yaml"):
        raise EvalError("the manifest workflow does not accept EVAL_DISCOVER or explicit EVAL_CONFIG")
    if env.get("EVAL_EXTRA_ARGS"):
        raise EvalError("EVAL_EXTRA_ARGS is not supported in manifest mode; settings belong in the manifest/eval YAML")
    if env.get("JOB_TYPE", "presubmit") != "presubmit":
        raise EvalError("manifest mode currently supports PR runs only (periodic/manual are follow-on work)")
    entries = load_manifest(repo)
    files = changed_files(repo, env.get("PULL_BASE_SHA", "")) if entries else []
    plans = []
    for entry in select_evals(entries, files):
        config, model = read_eval(repo, entry)
        plans.append(EvalPlan(entry.config, config, model, entry.parallelism, entry.max_turns,
                              entry.setup_script, select_cases(repo, entry, files) or ()))
    return plans


def main():
    env = dict(os.environ)
    repo = Path(env.get("EVAL_WORKDIR") or os.getcwd()).resolve()
    artifacts = Path(env["ARTIFACT_DIR"]).resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    env["ARTIFACT_DIR"] = str(artifacts)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        selected = manifest_plans(repo, env)
        if not selected:
            print("No evals matched; exiting without setup, harness installation, or Claude calls.", flush=True)
            results = []
            write_reports(artifacts, results, [], [])
            return int(bool(results))
    except (EvalError, Interrupted, OSError, ValueError) as error:
        print(f"ERROR: {error}", flush=True)
        write_reports(artifacts, [("eval selection", 0, str(error))], [], [str(error)])
        return 1
    return run_evals(repo, selected, artifacts, env)


if __name__ == "__main__":
    sys.exit(main())
