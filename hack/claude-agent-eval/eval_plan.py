"""Selected manifest evals and repository input validation."""

from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import subprocess

import yaml


class EvalError(Exception):
    """An invalid configuration or unsuccessful evaluation."""


@dataclass(frozen=True)
class EvalPlan:
    """One manifest eval with its resolved settings and selected cases."""

    config: str
    settings: dict
    model: str
    parallelism: int
    max_turns: int
    setup_script: str = ""
    cases: tuple = ()

    @property
    def artifact_name(self):
        """Keep artifact names readable and distinct across equal config basenames."""
        stem = re.sub(r"[^a-zA-Z0-9_-]", "-", Path(self.config).stem)[:80]
        suffix = hashlib.sha256(self.config.encode()).hexdigest()[:12]
        return f"{stem}-{suffix}"


def read_config(path):
    """Read an eval YAML without requiring manifest-owned model settings."""
    try:
        with path.open(encoding="utf-8") as stream:
            config = yaml.safe_load(stream)
    except (OSError, yaml.YAMLError) as error:
        raise EvalError(f"cannot read {path}: {error}") from error
    if not isinstance(config, dict):
        raise EvalError(f"{path}: eval config must be a mapping")
    return config


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


def changed_files(repo, base_sha):
    if not re.fullmatch(r"[0-9a-fA-F]{7,64}", base_sha):
        raise EvalError("changed-file selection requires PULL_BASE_SHA containing a Git commit SHA")
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
