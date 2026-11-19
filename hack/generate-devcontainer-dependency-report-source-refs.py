#!/usr/bin/env python3
"""Add the release source checkout to generated dependency-report periodics."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

import yaml

WORKFLOW = "openshift-devcontainer-dependency-report"
RELEASE_SOURCE_FILES = [
    "ci-operator/config/openshift/sippy/openshift-sippy-main__agentic.yaml",
    "ci-operator/config/openshift/origin/openshift-origin-main__agentic.yaml",
    (
        "ci-operator/config/openshift-eng/ship-status-dash/"
        "openshift-eng-ship-status-dash-main__agentic.yaml"
    ),
    (
        "ci-operator/step-registry/openshift/agentic/trt/init-model/"
        "openshift-agentic-trt-init-model-commands.sh"
    ),
    (
        "ci-operator/step-registry/openshift/agentic/trt/jira-solver/"
        "openshift-agentic-trt-jira-solver-commands.sh"
    ),
]
RELEASE_REF = {
    "base_ref": "main",
    "org": "openshift",
    "path_alias": "github.com/openshift/release",
    "repo": "release",
    "sparse_checkout_files": RELEASE_SOURCE_FILES,
}


class GenerationError(RuntimeError):
    """The source config or generated job did not have the expected shape."""


def require_mapping(value: Any, description: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GenerationError(f"{description} must be a mapping")
    return value


def opted_in_tests(config_dir: Path) -> list[tuple[dict[str, str], str]]:
    selected: list[tuple[dict[str, str], str]] = []
    for path in sorted(config_dir.rglob("*.yaml")):
        raw = path.read_text(encoding="utf-8")
        if WORKFLOW not in raw:
            continue
        document = yaml.safe_load(raw) or {}
        if not isinstance(document, dict):
            continue
        metadata = document.get("zz_generated_metadata")
        tests = document.get("tests", [])
        if not isinstance(metadata, dict) or not isinstance(tests, list):
            continue
        for test in tests:
            if not isinstance(test, dict):
                continue
            steps = test.get("steps")
            if not isinstance(steps, dict) or steps.get("workflow") != WORKFLOW:
                continue
            cron = test.get("cron")
            name = test.get("as")
            if not isinstance(cron, str) or not isinstance(name, str):
                raise GenerationError(
                    f"{path}: {WORKFLOW} test must be a named periodic"
                )
            identity: dict[str, str] = {}
            for field in ("org", "repo", "branch"):
                value = metadata.get(field)
                if not isinstance(value, str) or not value:
                    raise GenerationError(f"{path}: missing metadata {field}")
                identity[field] = value
            selected.append((identity, name))
    if not selected:
        raise GenerationError(f"no tests use {WORKFLOW}")
    return selected


def job_file(jobs_dir: Path, identity: dict[str, str]) -> Path:
    return (
        jobs_dir
        / identity["org"]
        / identity["repo"]
        / f"{identity['org']}-{identity['repo']}-{identity['branch']}-periodics.yaml"
    )


def render_refs(target_ref: dict[str, Any]) -> list[str]:
    lines = [
        "  extra_refs:\n",
        f"  - base_ref: {target_ref['base_ref']}\n",
        f"    org: {target_ref['org']}\n",
        f"    repo: {target_ref['repo']}\n",
        "    workdir: true\n",
    ]
    sparse = target_ref.get("sparse_checkout_files")
    if sparse is not None:
        if not isinstance(sparse, list) or not all(
            isinstance(item, str) for item in sparse
        ):
            raise GenerationError("target extra_ref sparse_checkout_files is invalid")
        lines.append("    sparse_checkout_files:\n")
        lines.extend(f"    - {item}\n" for item in sparse)
    lines.extend(
        [
            f"  - base_ref: {RELEASE_REF['base_ref']}\n",
            f"    org: {RELEASE_REF['org']}\n",
            f"    path_alias: {RELEASE_REF['path_alias']}\n",
            f"    repo: {RELEASE_REF['repo']}\n",
            "    sparse_checkout_files:\n",
            *(
                f"    - {file_path}\n"
                for file_path in RELEASE_REF["sparse_checkout_files"]
            ),
        ]
    )
    return lines


def update_job(path: Path, identity: dict[str, str], target: str) -> bool:
    text = path.read_text(encoding="utf-8")
    document = require_mapping(yaml.safe_load(text), str(path))
    periodics = document.get("periodics")
    if not isinstance(periodics, list):
        raise GenerationError(f"{path}: periodics must be a list")
    target_arg = f"--target={target}"
    matches: list[dict[str, Any]] = []
    for job in periodics:
        if not isinstance(job, dict):
            continue
        containers = require_mapping(job.get("spec"), f"{path}: job spec").get(
            "containers", []
        )
        if not isinstance(containers, list):
            continue
        if any(
            isinstance(container, dict)
            and isinstance(container.get("args"), list)
            and target_arg in container["args"]
            for container in containers
        ):
            matches.append(job)
    if len(matches) != 1:
        raise GenerationError(
            f"{path}: expected one generated periodic for {target!r}, found {len(matches)}"
        )
    job = matches[0]
    name = job.get("name")
    if not isinstance(name, str) or not name:
        raise GenerationError(f"{path}: selected periodic has no name")
    expected_identity = {
        "base_ref": identity["branch"],
        "org": identity["org"],
        "repo": identity["repo"],
    }
    refs = job.get("extra_refs")
    if not isinstance(refs, list) or not refs or not isinstance(refs[0], dict):
        raise GenerationError(f"{path}: selected periodic has unexpected extra_refs")
    target_ref = dict(refs[0])
    if any(target_ref.get(key) != value for key, value in expected_identity.items()):
        raise GenerationError(f"{path}: selected periodic has unexpected extra_refs")
    if len(refs) == 2:
        release_ref = refs[1]
        release_identity = {
            key: RELEASE_REF[key] for key in ("base_ref", "org", "path_alias", "repo")
        }
        if (
            not isinstance(release_ref, dict)
            or any(
                release_ref.get(key) != value for key, value in release_identity.items()
            )
            or target_ref.get("workdir") is not True
        ):
            raise GenerationError(
                f"{path}: selected periodic has unexpected extra_refs"
            )
        if release_ref == RELEASE_REF:
            return False
        target_ref.pop("workdir")
    elif len(refs) == 1 and "workdir" not in target_ref:
        pass
    else:
        raise GenerationError(f"{path}: selected periodic has unexpected extra_refs")

    lines = text.splitlines(keepends=True)
    name_line = f"  name: {name}\n"
    try:
        name_index = lines.index(name_line)
    except ValueError as exc:
        raise GenerationError(
            f"{path}: could not locate selected periodic text"
        ) from exc
    start = name_index
    while start >= 0 and not lines[start].startswith("- agent:"):
        start -= 1
    if start < 0:
        raise GenerationError(f"{path}: could not locate selected periodic start")
    end = name_index + 1
    while end < len(lines) and not lines[end].startswith("- agent:"):
        end += 1
    block = lines[start:end]
    try:
        refs_start = next(
            i for i, line in enumerate(block) if line == "  extra_refs:\n"
        )
        refs_end = next(
            i for i in range(refs_start + 1, len(block)) if block[i] == "  labels:\n"
        )
    except StopIteration as exc:
        raise GenerationError(
            f"{path}: could not locate selected extra_refs block"
        ) from exc
    block[refs_start:refs_end] = render_refs(target_ref)
    lines[start:end] = block
    path.write_text("".join(lines), encoding="utf-8")
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-dir", type=Path, required=True)
    parser.add_argument("--jobs-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    changed = 0
    for identity, target in opted_in_tests(args.config_dir):
        path = job_file(args.jobs_dir, identity)
        if not path.is_file():
            raise GenerationError(f"generated periodic file does not exist: {path}")
        changed += update_job(path, identity, target)
    print(f"release source refs ready; updated {changed} generated job file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
