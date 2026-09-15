"""Temporary EVAL_* input adapter; remove after legacy workflow migration.

This module only selects/configures evals. Setup, Claude, scoring, timeouts,
metrics and artifacts are owned by the shared Python execution engine.
"""

import fnmatch
from pathlib import Path
import shlex

try:  # Support both repository tooling and the standalone step bundle.
    from .eval_plan import EvalError, EvalPlan, changed_files, read_config
except ImportError:
    from eval_plan import EvalError, EvalPlan, changed_files, read_config


def positive_integer(env, name, default):
    """Reject unusable runner limits before setup or model calls."""
    try:
        value = int(env.get(name, default))
    except ValueError as error:
        raise EvalError(f"{name} must be a positive integer") from error
    if value <= 0:
        raise EvalError(f"{name} must be a positive integer")
    return value


def discover_configs(repo, pattern):
    """Match legacy find -path globs, excluding nested case YAML files."""
    pattern = "plugins/*/evals/*.yaml" if pattern == "true" else pattern
    return sorted(path.relative_to(repo).as_posix() for path in repo.rglob("*.yaml")
                  if path.is_file() and "/cases/" not in "/" + path.relative_to(repo).as_posix()
                  and fnmatch.fnmatchcase(path.relative_to(repo).as_posix(), pattern))


def legacy_cases(repo, config, env, files):
    """Retain changed-case precedence over the explicit comma-separated list."""
    cases = ()
    if env.get("EVAL_CHANGED_ONLY") == "true":
        directory = (str(Path(config).parent / Path(config).stem / "cases")
                     if env.get("EVAL_DISCOVER") else env.get("EVAL_CASES_DIR", ""))
        if directory and (repo / directory).is_dir():
            prefix = (repo / directory).resolve().relative_to(repo).as_posix() + "/"
            cases = tuple(sorted({path[len(prefix):].split("/", 1)[0]
                                  for path in files if path.startswith(prefix)}))
    if not cases:
        cases = tuple(env.get("EVAL_CASES", "").replace(",", " ").split())
    return cases


def load_legacy(repo, env):
    """Translate existing job inputs to the same plans used by manifest evals."""
    discovery = env.get("EVAL_DISCOVER", "")
    config = env.get("EVAL_CONFIG", "eval.yaml")
    if discovery and config not in ("", "eval.yaml"):
        raise EvalError("EVAL_DISCOVER and EVAL_CONFIG are mutually exclusive")
    configs = discover_configs(repo, discovery) if discovery else [config]
    changed_only = env.get("EVAL_CHANGED_ONLY") == "true"
    files = changed_files(repo, env["PULL_BASE_SHA"]) if changed_only and env.get("PULL_BASE_SHA") else []
    if discovery and changed_only and env.get("PULL_BASE_SHA"):
        # Legacy discovery matches skills inside plugins as well as at the root.
        configs = [path for path in configs if any(
            changed == path or changed.startswith(f"{Path(path).with_suffix('')}/")
            or f"/skills/{Path(path).stem}/" in f"/{changed}"
            for changed in files)]
    model = env.get("MULTISTAGE_PARAM_OVERRIDE_EVAL_MODEL") or env.get("EVAL_MODEL", "claude-opus-4-6")
    effort = env.get("MULTISTAGE_PARAM_OVERRIDE_EVAL_EFFORT") or env.get("EVAL_EFFORT", "")
    if not model.strip():
        raise EvalError("EVAL_MODEL must not be empty")
    parallelism = positive_integer(env, "EVAL_PARALLELISM", "1")
    max_turns = positive_integer(env, "EVAL_MAX_TURNS", "100")
    extra_args = []
    for flag, value in (("--effort", effort), ("--baseline", env.get("EVAL_BASELINE", ""))):
        if value:
            extra_args.extend((flag, value))
    extra_args.extend(shlex.split(env.get("EVAL_EXTRA_ARGS", "")))
    plans = []
    for path in configs:
        settings = read_config(repo / path)
        cases = legacy_cases(repo, path, env, files)
        if changed_only and not cases:
            print(f"SKIP {path}: no changed or explicit cases", flush=True)
            continue
        setup = env.get("EVAL_SETUP_SCRIPT", "")
        if setup and not (repo / setup).is_file():
            raise EvalError(f"EVAL_SETUP_SCRIPT not found: {setup}")
        plans.append(EvalPlan(path, settings, model, parallelism, max_turns,
                              setup, cases, tuple(extra_args), setup_once=True))
    return plans
