#!/usr/bin/env python3
"""Validate operator image-references and art.yaml against the CSV before merge."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

import yaml

RH_REGISTRY = "registry.redhat.io"
RELEASE_BRANCH_RE = re.compile(r"^release-(\d+)\.(\d+)$")
ZSTREAM_TAG_RE = re.compile(r"^v?\d+\.\d+\.\d+")
TEMPLATE_KEYS = ("MAJOR", "MINOR", "SUBMINOR", "RELEASE", "DATE_TIME", "FULL_VER")
TEMPLATE_PLACEHOLDER_RE = re.compile(
    r"\{(" + "|".join(TEMPLATE_KEYS) + r")\}"
)
RELEASE_REPO_NAME = "release"
IGNORED_BRANCHES = frozenset({"main", "master"})
REPORT_WIDTH = 72

RULE_GUIDE: dict[str, dict[str, str]] = {
    "R1": {
        "title": "Image in image-references is not in the CSV",
        "why": (
            "Each container image listed in image-references must also appear in the "
            "ClusterServiceVersion (CSV). If it does not, Doozer cannot update that image "
            "during rebase and the change is silently skipped."
        ),
        "fix": (
            "Add the pullspec to the CSV (relatedImages or annotations), or correct the "
            "image name in image-references."
        ),
    },
    "R2": {
        "title": "registry.redhat.io image does not match this release branch",
        "why": (
            "Red Hat payload images must use the openshift4/ or openshift5/ namespace for "
            "the OCP version on this branch, with an allowed tag (:latest, :X.Y, or :x.y.z)."
        ),
        "fix": (
            "Update the pullspec in image-references to the correct namespace and tag for "
            "this release branch."
        ),
    },
    "R3": {
        "title": "art.yaml tries to replace text that is not in the target file",
        "why": (
            "art.yaml lists find-and-replace edits Doozer runs at rebase time. The exact "
            "'search' text must already exist in the target file. If it does not, the edit "
            "does nothing."
        ),
        "fix": (
            "Update art.yaml search strings to match what is in the file today, or update "
            "the target manifest so the search text is present before the next rebase."
        ),
    },
}


@dataclass(frozen=True)
class BranchCandidate:
    source: str
    branch: str


@dataclass(frozen=True)
class BranchContext:
    """Resolved branch metadata for validation."""

    repo_branch: str
    repo_branch_source: str
    ocp_branch_name: Optional[str] = None
    ocp_branch_source: Optional[str] = None

    @property
    def ocp_branch(self) -> Optional["BranchVersion"]:
        if self.ocp_branch_name is None:
            return None
        return BranchVersion.from_release_branch(self.ocp_branch_name)

    @property
    def runs_ocp_checks(self) -> bool:
        return self.ocp_branch is not None


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
        """Compact single-violation format (used in unit tests)."""
        return format_violation_detail(self, Path("."))


def rel_path(path: Path, repo_root: Path) -> str:
    try:
        return str(path.resolve().relative_to(repo_root.resolve()))
    except ValueError:
        return str(path)


def format_violation_detail(violation: Violation, repo_root: Path) -> str:
    lines: list[str] = [f"  Problem: {violation.message}"]
    if violation.image_refs_path:
        lines.append(f"  image-references: {rel_path(violation.image_refs_path, repo_root)}")
    if violation.tag_name:
        lines.append(f"  image tag name: {violation.tag_name}")
    if violation.pullspec:
        lines.append(f"  pullspec: {violation.pullspec}")
    if violation.art_yaml_path:
        lines.append(f"  art.yaml: {rel_path(violation.art_yaml_path, repo_root)}")
    if violation.target_file:
        lines.append(f"  target file: {rel_path(violation.target_file, repo_root)}")
    if violation.search:
        lines.append(f"  text art.yaml expects to find: {violation.search!r}")
    return "\n".join(lines)


def format_failure_report(
    violations: list[Violation],
    release_branch: str,
    repo_root: Path,
) -> str:
    by_rule: dict[str, list[Violation]] = {"R1": [], "R2": [], "R3": []}
    for violation in violations:
        by_rule.setdefault(violation.rule, []).append(violation)

    lines: list[str] = [
        "=" * REPORT_WIDTH,
        f"ART manifest check FAILED  (branch {release_branch})",
        "=" * REPORT_WIDTH,
        "",
        f"Found {len(violations)} problem(s) in this operator repo.",
        "",
    ]

    for rule in ("R1", "R2", "R3"):
        rule_violations = by_rule.get(rule, [])
        if not rule_violations:
            continue
        guide = RULE_GUIDE.get(rule, {})
        title = guide.get("title", rule)
        lines.append("-" * REPORT_WIDTH)
        lines.append(f"{rule}: {title} ({len(rule_violations)})")
        lines.append("-" * REPORT_WIDTH)
        if guide.get("why"):
            lines.append(guide["why"])
            lines.append("")
        if guide.get("fix"):
            lines.append(f"How to fix: {guide['fix']}")
            lines.append("")

        for index, violation in enumerate(rule_violations, start=1):
            lines.append(f"({index})")
            lines.append(format_violation_detail(violation, repo_root))
            lines.append("")

    lines.extend(
        [
            "=" * REPORT_WIDTH,
            "Next steps",
            "=" * REPORT_WIDTH,
            "  - Fix the files listed above in the operator repository (not openshift/release).",
            "  - Re-run this check locally:",
            f"      python3 hack/art-manifests-validate/validate_art_manifests.py "
            f"--repo-root <operator-checkout> --release-branch {release_branch}",
            "  - Details: https://redhat.atlassian.net/browse/ART-14695",
            "",
        ]
    )
    return "\n".join(lines)


def is_release_branch(branch: str) -> bool:
    return bool(RELEASE_BRANCH_RE.match(branch.strip()))


def is_ocp_release_branch(branch: str) -> bool:
    """True for OpenShift release branches (release-4.y, release-5.y), not product branches like release-0.9."""
    version = BranchVersion.from_release_branch(branch)
    if version is None:
        return False
    return version.major >= 4


def is_ignored_branch(branch: str) -> bool:
    return branch.strip().lower() in IGNORED_BRANCHES


def contains_template_placeholders(value: str) -> bool:
    return bool(TEMPLATE_PLACEHOLDER_RE.search(value))


def read_git_branch(repo_root: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return ""
    if result.returncode != 0:
        return ""
    branch = result.stdout.strip()
    if branch in ("", "HEAD"):
        return ""
    return branch


def collect_branch_candidates(
    explicit: str = "",
    job_spec_json: str = "",
    pull_base_ref: str = "",
    git_branch: str = "",
) -> list[BranchCandidate]:
    candidates: list[BranchCandidate] = []

    def add(source: str, branch: Optional[str]) -> None:
        if branch and branch.strip():
            candidates.append(BranchCandidate(source=source, branch=branch.strip()))

    add("RELEASE_BRANCH", explicit)

    job_spec: Optional[dict] = None
    if job_spec_json:
        try:
            job_spec = json.loads(job_spec_json)
        except json.JSONDecodeError as exc:
            raise ValueError(f"JOB_SPEC is not valid JSON: {exc}") from exc

    add("PULL_BASE_REF", pull_base_ref)

    if job_spec:
        refs = job_spec.get("refs") or {}
        refs_org = refs.get("org") or ""
        refs_repo = refs.get("repo") or ""
        refs_base = refs.get("base_ref") or ""
        if refs_base and refs_repo != RELEASE_REPO_NAME:
            add(f"JOB_SPEC refs ({refs_org}/{refs_repo})", refs_base)

        for index, ref in enumerate(job_spec.get("extra_refs") or []):
            ref_base = ref.get("base_ref") or ""
            ref_org = ref.get("org") or ""
            ref_repo = ref.get("repo") or ""
            if ref_base:
                add(f"JOB_SPEC extra_refs[{index}] ({ref_org}/{ref_repo})", ref_base)

    add("git branch", git_branch)
    return candidates


def choose_branch_candidate(
    candidates: Iterable[BranchCandidate],
    *,
    predicate,
    explicit_source: str = "RELEASE_BRANCH",
) -> Optional[BranchCandidate]:
    candidate_list = list(candidates)
    explicit_matches = [c for c in candidate_list if c.source == explicit_source and predicate(c.branch)]
    if explicit_matches:
        return explicit_matches[0]

    matching = [c for c in candidate_list if predicate(c.branch)]
    if not matching:
        return None

    unique_branches = {candidate.branch for candidate in matching}
    if len(unique_branches) > 1:
        detail = ", ".join(f"{c.source}={c.branch!r}" for c in matching)
        raise ValueError(f"Conflicting branch candidates: {detail}")

    priority = (
        explicit_source,
        "PULL_BASE_REF",
        "JOB_SPEC refs (",
        "JOB_SPEC extra_refs[",
        "git branch",
    )
    for prefix in priority:
        for candidate in matching:
            if candidate.source == prefix or candidate.source.startswith(prefix):
                return candidate

    return matching[0]


def resolve_branch_context(
    explicit: str = "",
    job_spec_json: str = "",
    pull_base_ref: str = "",
    git_branch: str = "",
) -> BranchContext:
    """Resolve repo branch for reporting and optional OCP release-X.Y for R2/templates."""
    candidates = collect_branch_candidates(
        explicit=explicit,
        job_spec_json=job_spec_json,
        pull_base_ref=pull_base_ref,
        git_branch=git_branch,
    )

    repo_candidate = choose_branch_candidate(
        candidates,
        predicate=lambda branch: not is_ignored_branch(branch),
    )
    if repo_candidate is None:
        repo_candidate = choose_branch_candidate(candidates, predicate=lambda _branch: True)
    if repo_candidate is None:
        raise ValueError("Could not resolve a branch name from CI metadata or git.")

    ocp_candidate = choose_branch_candidate(
        candidates,
        predicate=is_ocp_release_branch,
    )

    return BranchContext(
        repo_branch=repo_candidate.branch,
        repo_branch_source=repo_candidate.source,
        ocp_branch_name=ocp_candidate.branch if ocp_candidate else None,
        ocp_branch_source=ocp_candidate.source if ocp_candidate else None,
    )


def resolve_release_branch(
    explicit: str = "",
    job_spec_json: str = "",
    pull_base_ref: str = "",
    git_branch: str = "",
) -> tuple[str, str]:
    """Resolve release-X.Y from CI metadata (OCP operators only).

    Raises ValueError when no OCP release branch is found or when candidates disagree.
    """
    candidates = collect_branch_candidates(
        explicit=explicit,
        job_spec_json=job_spec_json,
        pull_base_ref=pull_base_ref,
        git_branch=git_branch,
    )
    ocp_candidate = choose_branch_candidate(
        candidates,
        predicate=is_ocp_release_branch,
    )
    if ocp_candidate is None:
        observed = ", ".join(f"{c.source}={c.branch!r}" for c in candidates) or "(none)"
        raise ValueError(
            "Could not resolve a release-X.Y branch for OCP-specific rules. "
            f"Observed candidates: {observed}. "
            "Branches such as main/master are ignored for OCP detection."
        )
    return ocp_candidate.branch, ocp_candidate.source


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
    candidates = ", ".join(str(path) for path in unique)
    raise ValueError(
        f"Multiple *.clusterserviceversion.yaml files match {image_refs_path}; "
        f"cannot choose unambiguously: {candidates}"
    )


def find_art_yaml(image_refs_path: Path) -> Optional[Path]:
    refs_dir = image_refs_path.parent
    for candidate in (refs_dir / "art.yaml", refs_dir.parent / "art.yaml"):
        if candidate.is_file():
            return candidate
    return None


def load_image_references(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"Data in {path} is not a valid image-references file")
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
            continue

        violations.append(
            Violation(
                rule="R2",
                message=(
                    "registry.redhat.io tag must be :latest, the release minor version "
                    f"(:{branch.major}.{branch.minor}), or a z-stream tag (:x.y.z)"
                ),
                image_refs_path=image_refs_path,
                tag_name=tag_name,
                pullspec=pullspec,
            )
        )


def validate_r3_art_yaml(
    violations: list[Violation],
    art_yaml_path: Path,
    ocp_branch: Optional[BranchVersion] = None,
) -> None:
    templates = ocp_branch.template_values() if ocp_branch is not None else {}
    manifests_base = art_yaml_path.parent

    with art_yaml_path.open(encoding="utf-8") as handle:
        art_yaml_str = handle.read()

    parse_source = art_yaml_str
    if ocp_branch is not None and contains_template_placeholders(art_yaml_str):
        parse_source = expand_templates(art_yaml_str, templates)

    try:
        art_yaml_data = yaml.safe_load(parse_source)
    except yaml.YAMLError as exc:
        violations.append(
            Violation(
                rule="R3",
                message=f"art.yaml could not be parsed: {exc}",
                art_yaml_path=art_yaml_path,
            )
        )
        return

    if not isinstance(art_yaml_data, dict):
        violations.append(
            Violation(
                rule="R3",
                message="art.yaml did not parse to a mapping",
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
        if not isinstance(update, dict):
            violations.append(
                Violation(
                    rule="R3",
                    message="art.yaml `updates` entries must be mappings",
                    art_yaml_path=art_yaml_path,
                )
            )
            continue
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
        if not isinstance(update_list, list):
            violations.append(
                Violation(
                    rule="R3",
                    message=f"art.yaml update_list must be a list for file {relative_file!r}",
                    art_yaml_path=art_yaml_path,
                    target_file=manifests_base / relative_file,
                )
            )
            continue

        if Path(relative_file).is_absolute():
            violations.append(
                Violation(
                    rule="R3",
                    message="art.yaml target file must be a relative path within the manifests directory",
                    art_yaml_path=art_yaml_path,
                    target_file=Path(relative_file),
                )
            )
            continue

        base_dir = manifests_base.resolve()
        target_path = (manifests_base / relative_file).resolve()
        if target_path != base_dir and base_dir not in target_path.parents:
            violations.append(
                Violation(
                    rule="R3",
                    message="art.yaml target file must stay within the manifests directory",
                    art_yaml_path=art_yaml_path,
                    target_file=target_path,
                )
            )
            continue
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
            if not isinstance(entry, dict):
                violations.append(
                    Violation(
                        rule="R3",
                        message="art.yaml update_list entries must be mappings",
                        art_yaml_path=art_yaml_path,
                        target_file=target_path,
                    )
                )
                continue
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

            if contains_template_placeholders(search) and ocp_branch is None:
                violations.append(
                    Violation(
                        rule="R3",
                        message=(
                            "art.yaml search uses OCP version placeholders but no release-X.Y "
                            "branch was detected; cannot validate this search string"
                        ),
                        art_yaml_path=art_yaml_path,
                        target_file=target_path,
                        search=search,
                    )
                )
                continue

            expanded_search = (
                expand_templates(search, templates)
                if contains_template_placeholders(search)
                else search
            )
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


def validate_repo(repo_root: Path, branch_context: BranchContext) -> list[Violation]:
    violations: list[Violation] = []
    image_refs_files = find_image_references_files(repo_root)
    if not image_refs_files:
        return violations

    ocp_branch = branch_context.ocp_branch
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

        try:
            csv_path = find_csv_for_image_refs(image_refs_path)
        except ValueError as exc:
            violations.append(
                Violation(
                    rule="R1",
                    message=str(exc),
                    image_refs_path=image_refs_path,
                )
            )
            continue

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

        if ocp_branch is not None:
            validate_r2_branch_registry_rules(violations, image_refs_path, tags, ocp_branch)

        art_yaml_path = find_art_yaml(image_refs_path)
        if art_yaml_path is not None and art_yaml_path not in validated_art_yaml:
            validate_r3_art_yaml(violations, art_yaml_path, ocp_branch)
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
        default="",
        help=(
            "Optional OCP release branch (release-X.Y) for R2 and templated art.yaml rules. "
            "When unset, OCP rules run only if release-X.Y is detected from CI metadata "
            "or git. R1 and literal art.yaml checks always run."
        ),
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

    try:
        branch_context = resolve_branch_context(
            explicit=args.release_branch or os.environ.get("RELEASE_BRANCH", ""),
            job_spec_json=os.environ.get("JOB_SPEC", ""),
            pull_base_ref=os.environ.get("PULL_BASE_REF", ""),
            git_branch=read_git_branch(repo_root),
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    rules = "R1, R3"
    if branch_context.runs_ocp_checks:
        rules = "R1, R2, R3"
    print(
        f"Checking operator manifests for {branch_context.repo_branch} "
        f"(branch from {branch_context.repo_branch_source}; rules: {rules})"
    )
    if branch_context.runs_ocp_checks:
        assert branch_context.ocp_branch_name is not None
        assert branch_context.ocp_branch_source is not None
        print(
            f"OCP release branch {branch_context.ocp_branch_name} "
            f"(from {branch_context.ocp_branch_source}) enables R2 and templated art.yaml checks"
        )
    else:
        print("No release-X.Y branch detected; skipping OCP-specific R2 checks")

    violations = validate_repo(repo_root, branch_context)
    if not violations:
        print(
            f"PASSED: {len(image_refs_files)} image-references file(s) look good "
            f"for {branch_context.repo_branch}."
        )
        return 0

    print(format_failure_report(violations, branch_context.repo_branch, repo_root), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
