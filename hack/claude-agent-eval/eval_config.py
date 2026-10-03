#!/usr/bin/env python3
"""Resolve eval configuration through the pinned agent-eval-harness loader."""

import argparse
import importlib
import json
from dataclasses import dataclass
from pathlib import Path
import sys
from typing import Optional

try:
    from .eval_plan import EvalError, relative_path, repo_directory, repo_file, validate_thresholds
except ImportError:
    from eval_plan import EvalError, relative_path, repo_directory, repo_file, validate_thresholds


HARNESS_URL = "https://github.com/opendatahub-io/agent-eval-harness.git"
HARNESS_REVISION = "e4b0f24bdbaa33bb07e0d723dfd834e90b655b5f"
RESULT_SCHEMA_VERSION = 1


@dataclass(frozen=True)
class ResolvedConfig:
    """The minimal resolved runner settings and structured harness config."""

    config: str
    model: str
    settings: dict
    dataset_path: Optional[str]
    config_chain: tuple
    harness_config: object

    def as_dict(self):
        """Return the versioned bridge contract without dataclass internals."""
        return {
            "schema_version": RESULT_SCHEMA_VERSION,
            "config": self.config,
            "model": self.model,
            "settings": self.settings,
            "dataset_path": self.dataset_path,
            "config_chain": list(self.config_chain),
        }


def _import_harness_config(harness):
    """Import the config API from this checkout, never a consumer's package."""
    root = Path(harness).resolve()
    module_path = root / "agent_eval" / "config.py"
    if not module_path.is_file():
        raise EvalError(f"harness checkout does not contain {module_path.relative_to(root)}")

    # A caller may have imported a consumer-local package already. Remove only
    # foreign agent_eval modules so sys.path precedence also applies to the
    # import cache, not just to future module lookups.
    for name in list(sys.modules):
        if name == "agent_eval" or name.startswith("agent_eval."):
            module = sys.modules[name]
            location = getattr(module, "__file__", None)
            if not location or not Path(location).resolve().is_relative_to(root):
                del sys.modules[name]
    root_string = str(root)
    sys.path[:] = [item for item in sys.path if item and Path(item).resolve() != root]
    sys.path.insert(0, root_string)
    try:
        config_module = importlib.import_module("agent_eval.config")
    except (ImportError, OSError) as error:
        raise EvalError(f"cannot import agent_eval.config from {root}: {error}") from error
    imported_path = Path(config_module.__file__).resolve()
    if not imported_path.is_relative_to(root):
        raise EvalError(f"agent_eval.config was imported from outside the supplied harness: {imported_path}")
    if not callable(getattr(config_module, "load_raw", None)):
        raise EvalError("pinned harness agent_eval.config is missing load_raw()")
    eval_config = getattr(config_module, "EvalConfig", None)
    if eval_config is None or not callable(getattr(eval_config, "from_yaml", None)):
        raise EvalError("pinned harness agent_eval.config is missing EvalConfig.from_yaml()")
    return config_module


def _normalize_chain(repo, config_path, chain):
    if not isinstance(chain, (list, tuple)) or not chain:
        raise EvalError("harness load_raw() returned an empty or invalid config chain")
    normalized = []
    resolved_paths = []
    for item in chain:
        if not isinstance(item, str) or not item:
            raise EvalError("harness config chain entries must be nonempty path strings")
        path = Path(item)
        if not path.is_absolute():
            raise EvalError(f"harness config chain entry is not absolute: {item!r}")
        path = path.resolve()
        if not path.is_relative_to(repo) or not path.is_file():
            raise EvalError(f"inherited config must resolve to an existing file inside the repository: {item}")
        resolved_paths.append(path)
        normalized.append(path.relative_to(repo).as_posix())
    if len(set(resolved_paths)) != len(resolved_paths):
        raise EvalError("harness returned a config chain with repeated files")
    if resolved_paths[-1] != config_path:
        raise EvalError("harness config chain does not end at the selected overlay config")
    return tuple(normalized)


def resolve_config(harness, repo, config):
    """Resolve and validate one original config path using the harness APIs."""
    repo = Path(repo).resolve()
    config_value = Path(config)
    if config_value.is_absolute():
        config_path = config_value.resolve()
        if not config_path.is_relative_to(repo):
            raise EvalError(f"config must be inside the repository: {config}")
        identity = config_path.relative_to(repo).as_posix()
    else:
        identity = relative_path(config_value.as_posix(), "config")
        config_path = repo_file(repo, identity, "config")
    config_path = repo_file(repo, identity, "config")

    harness_config_module = _import_harness_config(harness)
    try:
        merged, chain = harness_config_module.load_raw(config_path)
    except Exception as error:  # harness exceptions need the selected config context
        raise EvalError(f"{identity}: harness load_raw() failed: {type(error).__name__}: {error}") from error
    if not isinstance(merged, dict):
        raise EvalError(f"{identity}: harness load_raw() did not return a mapping")

    # Keep release's structural guard on the merged value. In particular,
    # explicit null must not become the no-threshold default.
    validate_thresholds(merged.get("thresholds", {}))
    try:
        harness_config = harness_config_module.EvalConfig.from_yaml(config_path)
    except Exception as error:  # the harness owns structured eval validation
        raise EvalError(f"{identity}: EvalConfig.from_yaml() failed: {type(error).__name__}: {error}") from error

    models = getattr(harness_config, "models", None)
    model = getattr(models, "skill", None)
    if not isinstance(model, str) or not model.strip():
        raise EvalError(f"{identity}: models.skill is required; EVAL_MODEL is ignored")
    thresholds = validate_thresholds(getattr(harness_config, "thresholds", None))
    config_chain = _normalize_chain(repo, config_path, chain)

    dataset = getattr(harness_config, "dataset", None)
    dataset_value = getattr(dataset, "path", None)
    if dataset_value in (None, ""):
        dataset_path = None
    elif not isinstance(dataset_value, str):
        raise EvalError(f"{identity}: harness dataset.path must be a string")
    else:
        resolver = getattr(harness_config, "resolve_path", None)
        if not callable(resolver):
            raise EvalError(f"{identity}: pinned harness EvalConfig is missing resolve_path()")
        try:
            dataset_path = str(resolver(dataset_value).resolve())
        except Exception as error:
            raise EvalError(f"{identity}: harness could not resolve dataset.path: {error}") from error

    resolved = ResolvedConfig(identity, model, {"thresholds": thresholds}, dataset_path,
                              config_chain, harness_config)
    try:
        encoded = json.dumps(resolved.as_dict(), ensure_ascii=False, allow_nan=False)
        if json.loads(encoded) != resolved.as_dict():
            raise ValueError("JSON encoding would change resolved settings")
    except (TypeError, ValueError) as error:
        raise EvalError(f"{identity}: resolved settings are not JSON-safe: {error}") from error
    return resolved


def validate_resolution_result(document, repo, config, eval_cases_dir=""):
    """Validate the child's result file before it enters an eval plan."""
    if not isinstance(document, dict) or set(document) != {
            "schema_version", "config", "model", "settings", "dataset_path", "config_chain"}:
        raise EvalError("config resolver returned an incompatible result schema")
    version = document["schema_version"]
    if not isinstance(version, int) or isinstance(version, bool) or version != RESULT_SCHEMA_VERSION:
        raise EvalError(f"config resolver returned unsupported schema_version: {version!r}")
    if document["config"] != config:
        raise EvalError(f"config resolver identity mismatch: expected {config!r}, got {document['config']!r}")
    model = document["model"]
    if not isinstance(model, str) or not model.strip():
        raise EvalError("config resolver returned an empty or invalid model")
    settings = document["settings"]
    if not isinstance(settings, dict) or set(settings) != {"thresholds"}:
        raise EvalError("config resolver returned invalid settings")
    thresholds = validate_thresholds(settings["thresholds"])

    chain = document["config_chain"]
    if not isinstance(chain, list) or not chain:
        raise EvalError("config resolver returned an empty or invalid config_chain")
    resolved_chain = []
    for item in chain:
        relative_path(item, "config_chain")
        resolved_chain.append(repo_file(repo, item, "config_chain"))
    if len(set(resolved_chain)) != len(resolved_chain):
        raise EvalError("config resolver returned a config_chain with repeated files")
    expected_config = repo_file(repo, config, "config")
    if resolved_chain[-1] != expected_config:
        raise EvalError("config resolver returned a config_chain that does not end at the selected config")

    dataset_path = document["dataset_path"]
    if dataset_path is not None and (
            not isinstance(dataset_path, str) or not dataset_path or not Path(dataset_path).is_absolute()):
        raise EvalError("config resolver returned an invalid dataset_path")
    if eval_cases_dir:
        cases_path = repo_directory(repo, eval_cases_dir, "eval_cases_dir").resolve()
        resolved_dataset = Path(dataset_path).resolve() if dataset_path is not None else None
        if resolved_dataset != cases_path:
            raise EvalError(f"{config}: eval_cases_dir must point to the same directory "
                            "as the harness-resolved dataset.path")
    return {"model": model, "settings": {"thresholds": thresholds},
            "dataset_path": dataset_path, "config_chain": tuple(chain)}


def _write_result(destination, document):
    path = Path(destination)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(document, ensure_ascii=False, allow_nan=False,
                                    indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main(argv=None):
    """CLI used by the bounded runner child; diagnostics remain on stderr."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        resolved = resolve_config(args.harness, args.repo, args.config)
        _write_result(args.result, resolved.as_dict())
    except Exception as error:  # pylint: disable=broad-exception-caught
        # Harness imports and validation may raise implementation-specific errors.
        print(f"configuration resolution failed: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
