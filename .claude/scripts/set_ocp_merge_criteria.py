#!/usr/bin/env python3
"""Generate and audit OCP Tide merge criteria for a repository.

The generated query shape is:

* a release-branch query for existing 4.12+ branches through the minor release
  before the default branch's OCP promotion target (for example, ocp/5.1 means
  release-4.12 through release-5.0)
* a default-branch query for main, or master plus main when the default is master
* a complement query for every other branch, which also excludes every known
  release branch, gated only on approved and lgtm
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PROW_CONFIG_DIR = REPO_ROOT / "core-services" / "prow" / "02_config"
CI_OPERATOR_CONFIG_DIR = REPO_ROOT / "ci-operator" / "config"
RELEASES_DIR = REPO_ROOT / "core-services" / "release-controller" / "_releases"

MISSING_LABELS = [
    "backports/unvalidated-commits",
    "do-not-merge/hold",
    "do-not-merge/invalid-owners-file",
    "do-not-merge/work-in-progress",
    "jira/invalid-bug",
]
DEFAULT_LABELS = ["approved", "jira/valid-reference", "lgtm", "verified"]
RELEASE_LABELS = ["approved", "backport-risk-assessed", "jira/valid-bug", "lgtm", "verified"]
COMPLEMENT_LABELS = ["approved", "lgtm"]

RELEASE_BRANCH_RE = re.compile(r"^(release|openshift)-(\d+)\.(\d+)$")
RELEASE_FILE_RE = re.compile(r"^release-ocp-(\d+)\.(\d+)\.json$")
MIN_RELEASE_VERSION = (4, 12)


def run(command: list[str], *, input_text: str | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            check=True,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as error:
        raise SystemExit(f"required command not found: {command[0]}") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip() or str(error)
        raise SystemExit(f"command failed: {' '.join(command)}\n{detail}") from error
    return result.stdout


def load_remote_metadata(org_repo: str) -> tuple[str, list[str]]:
    default_branch = run(
        ["gh", "api", f"repos/{org_repo}", "--jq", ".default_branch"]
    ).strip()
    if not default_branch:
        raise SystemExit(f"could not determine the default branch for {org_repo}")

    branches_output = run(
        [
            "gh",
            "api",
            f"repos/{org_repo}/branches",
            "--paginate",
            "--jq",
            ".[].name",
        ]
    )
    branches = sorted({line.strip() for line in branches_output.splitlines() if line.strip()})
    return default_branch, branches


def parse_branch(branch: str) -> tuple[tuple[int, int], str] | None:
    match = RELEASE_BRANCH_RE.fullmatch(branch)
    if not match:
        return None
    prefix, major, minor = match.groups()
    return (int(major), int(minor)), prefix


def ocp_promotion_version(repo: str, default_branch: str) -> tuple[int, int]:
    org, name = repo.split("/", 1)
    path = CI_OPERATOR_CONFIG_DIR / org / name / f"{org}-{name}-{default_branch}.yaml"
    if not path.is_file():
        raise SystemExit(
            f"could not find the default-branch ci-operator config at "
            f"{path.relative_to(REPO_ROOT)}"
        )

    data = json.loads(run(["yq", "-o=json", ".", str(path)]))
    targets = (data.get("promotion") or {}).get("to") or []
    versions = {
        str(target["name"])
        for target in targets
        if isinstance(target, dict)
        and target.get("namespace") == "ocp"
        and target.get("disabled") is not True
    }
    if not versions:
        raise SystemExit(f"{path.relative_to(REPO_ROOT)} has no enabled ocp promotion target")
    if len(versions) != 1:
        raise SystemExit(
            f"{path.relative_to(REPO_ROOT)} has multiple ocp promotion targets: "
            f"{', '.join(sorted(versions))}"
        )
    return parse_version(versions.pop())


def parse_version(version: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+)\.(\d+)", version)
    if not match:
        raise SystemExit(f"invalid OCP version {version!r}; expected X.Y")
    return int(match.group(1)), int(match.group(2))


def known_ocp_versions(branches: list[str]) -> set[tuple[int, int]]:
    versions = set()
    for path in RELEASES_DIR.glob("release-ocp-*.json"):
        match = RELEASE_FILE_RE.fullmatch(path.name)
        if match:
            versions.add((int(match.group(1)), int(match.group(2))))
    for branch in branches:
        parsed = parse_branch(branch)
        if parsed is not None:
            versions.add(parsed[0])
    return versions


def previous_version(
    version: tuple[int, int], known_versions: set[tuple[int, int]]
) -> tuple[int, int]:
    earlier = [candidate for candidate in known_versions if candidate < version]
    if earlier:
        return max(earlier)
    major, minor = version
    if minor > 0:
        return major, minor - 1
    raise SystemExit(f"could not determine the release before OCP {major}.{minor}")


def release_query_branches(
    branches: list[str], previous: tuple[int, int], minimum: tuple[int, int]
) -> list[str]:
    include_openshift = any(
        (parsed := parse_branch(branch)) is not None and parsed[1] == "openshift"
        for branch in branches
    )
    versions = {
        parsed[0]
        for branch in branches
        if (parsed := parse_branch(branch)) is not None
        and minimum <= parsed[0] <= previous
    }
    result = []
    for major, minor in sorted(versions):
        result.append(f"release-{major}.{minor}")
        if include_openshift:
            result.append(f"openshift-{major}.{minor}")
    return sorted(result)


def all_release_branches(branches: list[str]) -> list[str]:
    return sorted(branch for branch in branches if parse_branch(branch) is not None)


def default_query_branches(default_branch: str) -> list[str]:
    if default_branch == "main":
        return ["main"]
    if default_branch == "master":
        return ["main", "master"]
    raise SystemExit(
        f"default branch {default_branch!r} does not look like an OCP default branch; "
        "expected main or master"
    )


def make_query(
    repo: str,
    *,
    labels: list[str],
    included_branches: list[str] | None = None,
    excluded_branches: list[str] | None = None,
) -> dict[str, object]:
    query: dict[str, object] = {}
    if included_branches:
        query["includedBranches"] = sorted(included_branches)
    if excluded_branches:
        query["excludedBranches"] = sorted(excluded_branches)
    query["labels"] = sorted(labels)
    query["missingLabels"] = MISSING_LABELS
    query["repos"] = [repo]
    return query


def build_queries(
    repo: str,
    default_branch: str,
    branches: list[str],
    promotion_version: tuple[int, int],
    minimum: tuple[int, int],
) -> tuple[list[dict[str, object]], list[str], list[str]]:
    previous = previous_version(promotion_version, known_ocp_versions(branches))
    release = release_query_branches(branches, previous, minimum)
    known_release = all_release_branches(branches)
    default = default_query_branches(default_branch)

    queries = []
    if release:
        queries.append(make_query(repo, labels=RELEASE_LABELS, included_branches=release))
    queries.append(make_query(repo, labels=DEFAULT_LABELS, included_branches=default))
    queries.append(
        make_query(
            repo,
            labels=COMPLEMENT_LABELS,
            excluded_branches=sorted(set(known_release + default)),
        )
    )
    return queries, release, known_release


def yaml_queries(queries: list[dict[str, object]]) -> str:
    lines = ["  queries:"]
    for query in queries:
        if "includedBranches" in query:
            lines.append("  - includedBranches:")
            lines.extend(f"    - {branch}" for branch in query["includedBranches"])
        elif "excludedBranches" in query:
            lines.append("  - excludedBranches:")
            lines.extend(f"    - {branch}" for branch in query["excludedBranches"])

        lines.append("    labels:")
        lines.extend(f"    - {label}" for label in query["labels"])
        lines.append("    missingLabels:")
        lines.extend(f"    - {label}" for label in query["missingLabels"])
        lines.append("    repos:")
        lines.extend(f"    - {repo}" for repo in query["repos"])
    return "\n".join(lines)


def normalize_query(query: dict[str, object]) -> dict[str, object]:
    return {
        "includedBranches": sorted(query.get("includedBranches") or []),
        "excludedBranches": sorted(query.get("excludedBranches") or []),
        "labels": sorted(query.get("labels") or []),
        "missingLabels": sorted(query.get("missingLabels") or []),
        "repos": sorted(query.get("repos") or []),
    }


def query_fingerprints(queries: list[dict[str, object]]) -> collections.Counter[str]:
    return collections.Counter(
        json.dumps(normalize_query(query), sort_keys=True) for query in queries
    )


def check_config(repo: str, expected: list[dict[str, object]]) -> int:
    org, name = repo.split("/", 1)
    path = PROW_CONFIG_DIR / org / name / "_prowconfig.yaml"
    if not path.is_file():
        print(f"{path.relative_to(REPO_ROOT)} does not exist", file=sys.stderr)
        return 1

    data = json.loads(run(["yq", "-o=json", ".", str(path)]))
    existing_queries = (data.get("tide") or {}).get("queries") or []
    actual = [
        query
        for query in existing_queries
        if repo in (query.get("repos") or [])
    ]

    if query_fingerprints(actual) == query_fingerprints(expected):
        print(f"{path.relative_to(REPO_ROOT)} matches the OCP merge criteria")
        return 0

    print(f"{path.relative_to(REPO_ROOT)} does not match the expected queries", file=sys.stderr)
    print("\nExpected query block:\n", file=sys.stderr)
    print(yaml_queries(expected), file=sys.stderr)
    return 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repo", help="GitHub repository as org/repo")
    parser.add_argument("--default-branch", help="override the repository default branch")
    parser.add_argument(
        "--branches-file",
        type=Path,
        help="read branch names from this file instead of GitHub (one per line)",
    )
    parser.add_argument("--promotion-version", help="override the default-branch OCP promotion version")
    parser.add_argument(
        "--min-release",
        default="4.12",
        help="oldest release branch to include in the strict release query (default: 4.12)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="compare the repository _prowconfig.yaml with the expected queries",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.repo.count("/") != 1:
        raise SystemExit("repo must be specified as org/repo")

    if args.branches_file:
        branches = sorted(
            {
                line.strip()
                for line in args.branches_file.read_text(encoding="utf-8").splitlines()
                if line.strip()
            }
        )
        default_branch = args.default_branch
        if not default_branch:
            raise SystemExit("--default-branch is required with --branches-file")
    else:
        remote_default, branches = load_remote_metadata(args.repo)
        default_branch = args.default_branch or remote_default

    promotion_version = (
        parse_version(args.promotion_version)
        if args.promotion_version
        else ocp_promotion_version(args.repo, default_branch)
    )
    minimum = parse_version(args.min_release)
    queries, release, known_release = build_queries(
        args.repo, default_branch, branches, promotion_version, minimum
    )

    if args.check:
        return check_config(args.repo, queries)

    print(f"default branch: {default_branch}")
    print(f"ocp promotion target: {promotion_version[0]}.{promotion_version[1]}")
    print(f"release query branches: {', '.join(release)}")
    print(f"known release branches excluded by complement: {', '.join(known_release)}")
    print()
    print(yaml_queries(queries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
