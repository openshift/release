"""Selected manifest evals and repository input validation."""

from dataclasses import dataclass
import hashlib
from pathlib import Path
import re
from typing import Optional


class EvalError(Exception):
    """An invalid configuration or unsuccessful evaluation."""


def artifact_name(config):
    """Keep artifact names readable and distinct across equal config basenames."""
    stem = re.sub(r"[^a-zA-Z0-9_-]", "-", Path(config).stem)[:80]
    suffix = hashlib.sha256(config.encode()).hexdigest()[:12]
    return f"{stem}-{suffix}"


@dataclass(frozen=True)
class EvalPlan:  # pylint: disable=too-many-instance-attributes
    """One manifest eval with its resolved settings and selected cases."""

    config: str
    settings: dict
    model: str
    parallelism: int
    max_turns: int
    setup_script: str = ""
    cases: tuple = ()
    config_chain: tuple = ()
    eval_name: str = ""
    # Preflight-resolved identity the post-run check compares the run against;
    # never re-read from the eval YAML after the orchestrator has run.
    skill: Optional[str] = None
    dataset_path: Optional[str] = None

    @property
    def artifact_name(self):
        """Return the stable directory name for this config identity."""
        return artifact_name(self.config)


def validate_eval_name(value, field):
    """Require the single path segment the harness uses under the runs directory."""
    if not isinstance(value, str) or value in ("", ".", ".."):
        raise EvalError(f"{field} must be a nonempty single path segment: {value!r}")
    if any(c in "/\\" or ord(c) < 32 for c in value):
        raise EvalError(f"{field} must be a single path segment without separators: {value!r}")
    return value


def validate_thresholds(thresholds):
    """Validate container types; leave scoring rules to the harness."""
    if not isinstance(thresholds, dict):
        raise EvalError("thresholds must be a mapping; omit it or use {} for no thresholds")
    for judge, limits in thresholds.items():
        if not isinstance(judge, str) or not judge.strip() or not isinstance(limits, dict):
            raise EvalError("thresholds must map nonempty judge names to mappings")
    return thresholds


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
