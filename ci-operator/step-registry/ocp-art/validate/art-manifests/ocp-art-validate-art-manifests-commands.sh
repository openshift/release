#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "PyYAML not found; installing..."
    python3 -m pip install --disable-pip-version-check --no-cache-dir pyyaml
fi

RELEASE_BRANCH="${RELEASE_BRANCH:-}"
if [[ -z "${RELEASE_BRANCH}" && -n "${JOB_SPEC:-}" ]]; then
    RELEASE_BRANCH="$(echo "${JOB_SPEC}" | jq -r '.refs.base_ref // .extra_refs[0].base_ref // empty')"
fi

if [[ -z "${RELEASE_BRANCH}" ]]; then
    echo "ERROR: RELEASE_BRANCH is required (set explicitly or via JOB_SPEC base_ref)"
    exit 1
fi

echo "Validating ART manifests for branch ${RELEASE_BRANCH} in ${PWD}"
export ART_VALIDATE_REPO_ROOT="${PWD}"
export ART_VALIDATE_RELEASE_BRANCH="${RELEASE_BRANCH}"
python3 <<'PYVALIDATOR'
#!/usr/bin/env python3
"""Validate operator image-references and art.yaml against the CSV before merge."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

import yaml

RH_REGISTRY = "registry.redhat.io"
RELEASE_BRANCH_RE = re.compile(r"^release-(\d+)\.(\d+)$")
ZSTREAM_TAG_RE = re.compile(r"^v?\d+\.\d+\.\d+")
TEMPLATE_KEYS = ("MAJOR", "MINOR", "SUBMINOR", "RELEASE", "DATE_TIME", "FULL_VER")


@dataclass(frozen=True)
class BranchVersion:
    major: int
    minor: int

    @classmethod
    def from_release_branch(cls, branch: str) -> Optional["BranchVersion"]:
        match = RELEASE_BRANCH_RE.match(branch.strip())
        if not match:
            return None
        return cls(major=int(match.group(1)), minor=int(match.group(2)))

    def template_values(self) -> dict[str, str]:
        version = f"{self.major}.{self.minor}.0"
        release = "0"
        date_time = "0"
        return {
            "MAJOR": str(self.major),
            "MINOR": str(self.minor),
            "SUBMINOR": "0",
            "RELEASE": release,
            "DATE_TIME": date_time,
            "FULL_VER": f"{version}-{date_time}",
        }


@dataclass
class Violation:
    rule: str
    message: str
    image_refs_path: Optional[Path] = None
    tag_name: Optional[str] = None
    pullspec: Optional[str] = None
    art_yaml_path: Optional[Path] = None
    target_file: Optional[Path] = None
    search: Optional[str] = None

    def format(self) -> str:
        lines = [f"[{self.rule}] {self.message}"]
        if self.image_refs_path:
            lines.append(f"  image-references: {self.image_refs_path}")
        if self.tag_name:
            lines.append(f"  tag: {self.tag_name}")
        if self.pullspec:
            lines.append(f"  pullspec: {self.pullspec}")
        if self.art_yaml_path:
            lines.append(f"  art.yaml: {self.art_yaml_path}")
        if self.target_file:
            lines.append(f"  target file: {self.target_file}")
        if self.search:
            lines.append(f"  search: {self.search!r}")
        return "\n".join(lines)


def expand_templates(value: str, templates: dict[str, str]) -> str:
    result = value
    for key in TEMPLATE_KEYS:
        result = result.replace("{" + key + "}", templates[key])
    return result


def find_image_references_files(repo_root: Path) -> list[Path]:
    return sorted(
        path
        for path in repo_root.rglob("image-references")
        if path.is_file() and "vendor" not in path.parts and ".git" not in path.parts
    )


def candidate_csv_dirs(image_refs_path: Path) -> list[Path]:
    refs_dir = image_refs_path.parent
    dirs: list[Path] = [refs_dir]
    for name in ("stable", "manifests"):
        child = refs_dir / name
        if child.is_dir():
            dirs.append(child)
    parent = refs_dir.parent
    if parent != refs_dir:
        for child in sorted(parent.iterdir()):
            if child.is_dir() and child not in dirs:
                dirs.append(child)
    return dirs


def find_csv_for_image_refs(image_refs_path: Path) -> Optional[Path]:
    csv_files: list[Path] = []
    for directory in candidate_csv_dirs(image_refs_path):
        csv_files.extend(sorted(directory.glob("*.clusterserviceversion.yaml")))
    unique = []
    seen = set()
    for path in csv_files:
        if path not in seen:
            unique.append(path)
            seen.add(path)
    if not unique:
        return None
    if len(unique) == 1:
        return unique[0]
    refs_dir = image_refs_path.parent
    same_dir = [path for path in unique if path.parent == refs_dir]
    if len(same_dir) == 1:
        return same_dir[0]
    stable_dir = refs_dir / "stable"
    stable_matches = [path for path in unique if path.parent == stable_dir]
    if len(stable_matches) == 1:
        return stable_matches[0]
    manifests_dir = refs_dir / "manifests"
    manifests_matches = [path for path in unique if path.parent == manifests_dir]
    if len(manifests_matches) == 1:
        return manifests_matches[0]
    return unique[0]


def find_art_yaml(image_refs_path: Path) -> Optional[Path]:
    refs_dir = image_refs_path.parent
    for candidate in (refs_dir / "art.yaml", refs_dir.parent / "art.yaml"):
        if candidate.is_file():
            return candidate
    return None


def load_image_references(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    tags = data.get("spec", {}).get("tags", [])
    if not isinstance(tags, list) or not tags:
        raise ValueError(f"Data in {path} is not a valid image-references file")
    return tags


def validate_r1_pullspec_in_csv(
    violations: list[Violation],
    image_refs_path: Path,
    csv_path: Path,
    tags: Iterable[dict],
    csv_content: str,
) -> None:
    for tag in tags:
        tag_name = tag.get("name", "<unknown>")
        pullspec = tag.get("from", {}).get("name")
        if not isinstance(pullspec, str) or not pullspec:
            violations.append(
                Violation(
                    rule="R1",
                    message="image-references tag is missing from.name pullspec",
                    image_refs_path=image_refs_path,
                    tag_name=tag_name,
                )
            )
            continue
        if pullspec not in csv_content:
            violations.append(
                Violation(
                    rule="R1",
                    message=(
                        "pullspec from image-references does not appear in the CSV; "
                        "Doozer str.replace would be a silent no-op"
                    ),
                    image_refs_path=image_refs_path,
                    tag_name=tag_name,
                    pullspec=pullspec,
                    target_file=csv_path,
                )
            )


def parse_rh_pullspec(pullspec: str) -> tuple[str, str]:
    without_scheme = pullspec[len("registry.redhat.io/") :]
    repo, _, tag = without_scheme.rpartition(":")
    if not tag:
        tag = "latest"
    return repo, tag


def validate_r2_branch_registry_rules(
    violations: list[Violation],
    image_refs_path: Path,
    tags: Iterable[dict],
    branch: BranchVersion,
) -> None:
    expected_namespace = "openshift5" if branch.major == 5 else "openshift4"
    allowed_tags = {"latest", f"{branch.major}.{branch.minor}", f"v{branch.major}.{branch.minor}"}

    for tag in tags:
        tag_name = tag.get("name", "<unknown>")
        pullspec = tag.get("from", {}).get("name")
        if not isinstance(pullspec, str) or not pullspec.startswith(f"{RH_REGISTRY}/"):
            continue

        repo, image_tag = parse_rh_pullspec(pullspec)
        namespace = repo.split("/", 1)[0]
        if namespace != expected_namespace:
            violations.append(
                Violation(
                    rule="R2",
                    message=(
                        f"registry.redhat.io image must use namespace {expected_namespace}/ "
                        f"on release-{branch.major}.{branch.minor}"
                    ),
                    image_refs_path=image_refs_path,
                    tag_name=tag_name,
                    pullspec=pullspec,
                )
            )

        normalized_tag = image_tag
        if normalized_tag in allowed_tags:
            continue
        if ZSTREAM_TAG_RE.match(normalized_tag):
            violations.append(
                Violation(
                    rule="R2",
                    message=(
                        "registry.redhat.io tag must be :latest or the release minor version "
                        f"(:{branch.major}.{branch.minor}); z-stream tags are not allowed"
                    ),
                    image_refs_path=image_refs_path,
                    tag_name=tag_name,
                    pullspec=pullspec,
                )
            )
            continue

        violations.append(
            Violation(
                rule="R2",
                message=(
                    "registry.redhat.io tag must be :latest or the release minor version "
                    f"(:{branch.major}.{branch.minor})"
                ),
                image_refs_path=image_refs_path,
                tag_name=tag_name,
                pullspec=pullspec,
            )
        )


def validate_r3_art_yaml(
    violations: list[Violation],
    art_yaml_path: Path,
    branch: BranchVersion,
) -> None:
    templates = branch.template_values()
    manifests_base = art_yaml_path.parent

    with art_yaml_path.open(encoding="utf-8") as handle:
        art_yaml_str = handle.read()

    try:
        expanded = expand_templates(art_yaml_str, templates)
        art_yaml_data = yaml.safe_load(expanded)
    except (yaml.YAMLError, ValueError) as exc:
        violations.append(
            Violation(
                rule="R3",
                message=f"art.yaml could not be parsed after template expansion: {exc}",
                art_yaml_path=art_yaml_path,
            )
        )
        return

    updates = art_yaml_data.get("updates", [])
    if not updates:
        return
    if not isinstance(updates, list):
        violations.append(
            Violation(
                rule="R3",
                message="art.yaml `updates` must be a list",
                art_yaml_path=art_yaml_path,
            )
        )
        return

    for update in updates:
        relative_file = update.get("file")
        update_list = update.get("update_list", [])
        if not relative_file:
            violations.append(
                Violation(
                    rule="R3",
                    message="art.yaml update is missing `file`",
                    art_yaml_path=art_yaml_path,
                )
            )
            continue
        if not update_list:
            violations.append(
                Violation(
                    rule="R3",
                    message=f"art.yaml update_list is empty for file {relative_file!r}",
                    art_yaml_path=art_yaml_path,
                    target_file=manifests_base / relative_file,
                )
            )
            continue

        target_path = manifests_base / relative_file
        if not target_path.is_file():
            violations.append(
                Violation(
                    rule="R3",
                    message="art.yaml target file does not exist",
                    art_yaml_path=art_yaml_path,
                    target_file=target_path,
                )
            )
            continue

        with target_path.open(encoding="utf-8") as handle:
            target_content = handle.read()

        for entry in update_list:
            search = entry.get("search")
            replace = entry.get("replace")
            if search is None or replace is None:
                violations.append(
                    Violation(
                        rule="R3",
                        message="art.yaml update_list entry must include `search` and `replace`",
                        art_yaml_path=art_yaml_path,
                        target_file=target_path,
                    )
                )
                continue
            if not isinstance(search, str) or not isinstance(replace, str):
                violations.append(
                    Violation(
                        rule="R3",
                        message="art.yaml `search` and `replace` must be strings",
                        art_yaml_path=art_yaml_path,
                        target_file=target_path,
                        search=str(search),
                    )
                )
                continue
            if not search:
                violations.append(
                    Violation(
                        rule="R3",
                        message="art.yaml `search` cannot be empty",
                        art_yaml_path=art_yaml_path,
                        target_file=target_path,
                    )
                )
                continue

            expanded_search = expand_templates(search, templates)
            if expanded_search not in target_content:
                violations.append(
                    Violation(
                        rule="R3",
                        message=(
                            "art.yaml search string not found in target file; "
                            "Doozer would log an ineffective replace at rebase time"
                        ),
                        art_yaml_path=art_yaml_path,
                        target_file=target_path,
                        search=expanded_search,
                    )
                )


def validate_repo(repo_root: Path, release_branch: str) -> list[Violation]:
    violations: list[Violation] = []
    image_refs_files = find_image_references_files(repo_root)
    if not image_refs_files:
        return violations

    branch = BranchVersion.from_release_branch(release_branch)
    validated_art_yaml: set[Path] = set()

    for image_refs_path in image_refs_files:
        try:
            tags = load_image_references(image_refs_path)
        except ValueError as exc:
            violations.append(
                Violation(
                    rule="R1",
                    message=str(exc),
                    image_refs_path=image_refs_path,
                )
            )
            continue

        csv_path = find_csv_for_image_refs(image_refs_path)
        if csv_path is None:
            violations.append(
                Violation(
                    rule="R1",
                    message="image-references exists but no *.clusterserviceversion.yaml was found",
                    image_refs_path=image_refs_path,
                )
            )
            continue

        csv_content = csv_path.read_text(encoding="utf-8")
        validate_r1_pullspec_in_csv(violations, image_refs_path, csv_path, tags, csv_content)

        if branch is not None:
            validate_r2_branch_registry_rules(violations, image_refs_path, tags, branch)

        art_yaml_path = find_art_yaml(image_refs_path)
        if art_yaml_path is not None and art_yaml_path not in validated_art_yaml:
            if branch is None:
                violations.append(
                    Violation(
                        rule="R3",
                        message=(
                            f"art.yaml found but release branch {release_branch!r} is not "
                            "release-X.Y; cannot expand templates for validation"
                        ),
                        art_yaml_path=art_yaml_path,
                    )
                )
            else:
                validate_r3_art_yaml(violations, art_yaml_path, branch)
            validated_art_yaml.add(art_yaml_path)

    return violations


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Root of the operator repository checkout",
    )
    parser.add_argument(
        "--release-branch",
        required=True,
        help="Target release branch (e.g. release-4.23, release-5.0)",
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    if not repo_root.is_dir():
        print(f"ERROR: repo root does not exist: {repo_root}", file=sys.stderr)
        return 2

    image_refs_files = find_image_references_files(repo_root)
    if not image_refs_files:
        print(f"No image-references files found under {repo_root}; skipping validation.")
        return 0

    violations = validate_repo(repo_root, args.release_branch)
    if not violations:
        print(
            f"Validated {len(image_refs_files)} image-references file(s) "
            f"for {args.release_branch}."
        )
        return 0

    print("ART manifest validation failed:", file=sys.stderr)
    for violation in violations:
        print(violation.format(), file=sys.stderr)
        print(file=sys.stderr)
    print(
        "Fix image-references pullspecs and art.yaml search strings before merging. "
        "See ART-14695 for rule details.",
        file=sys.stderr,
    )
    return 1

if __name__ == "__main__":
    import os
    import sys
    sys.exit(
        main(
            [
                "--repo-root",
                os.environ["ART_VALIDATE_REPO_ROOT"],
                "--release-branch",
                os.environ["ART_VALIDATE_RELEASE_BRANCH"],
            ]
        )
    )
PYVALIDATOR
