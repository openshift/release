#!/usr/bin/env python3
"""Report public devcontainer dependency versions without changing repositories."""

# Keep annotations and UTC handling compatible with Python 3.9.
# ruff: noqa: UP007, UP017, UP045

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Optional, Union

STABLE_COMPONENT = r"(?:0|[1-9]\d*)"
STABLE_VERSION = re.compile(
    rf"^({STABLE_COMPONENT})\.({STABLE_COMPONENT})\.({STABLE_COMPONENT})$"
)
CLASSIFICATIONS = {"pinned", "floating", "repo-coupled", "manual", "unsupported"}
GITHUB_PAGE_LIMIT = 10
POLICY_REPOSITORY = "openshift/release"
POLICY_REF = "main"
POLICY_PATH = (
    "ci-operator/step-registry/openshift/devcontainer-dependency-report/"
    "openshift-devcontainer-dependency-report-config.md"
)
PERIODIC_JOB_BY_REPOSITORY = {
    "openshift/sippy": "periodic-ci-openshift-sippy-main-agentic-periodic-sippy-devcontainer-dependency-report",
    "openshift/origin": "periodic-ci-openshift-origin-main-agentic-periodic-origin-devcontainer-dependency-report",
    "openshift-eng/ship-status-dash": "periodic-ci-openshift-eng-ship-status-dash-main-agentic-periodic-ship-status-dash-devcontainer-dependency-report",
}
REPOSITORY_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
COMMIT_SHA = re.compile(r"^[0-9a-f]{40}$")
GITHUB_API_PATH = re.compile(
    r"^/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/"
    r"(?:commits/[^/]+|pulls/[1-9]\d*|releases|tags)$"
)
RAW_GITHUB_PATH = re.compile(r"^/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[0-9a-f]{40}/.+$")
NPM_PATH = re.compile(
    r"^/(?:[A-Za-z0-9_.~-]+|@[A-Za-z0-9_.~-]+%2[fF][A-Za-z0-9_.~-]+)$"
)
PYPI_PATH = re.compile(r"^/pypi/[A-Za-z0-9_.-]+/json$")


class CheckError(RuntimeError):
    """An expected lookup, extraction, or policy failure."""


def parsed_public_https_url(url: str) -> urllib.parse.SplitResult:
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except (TypeError, ValueError) as exc:
        raise CheckError(f"invalid lookup URL {url!r}: {exc}") from exc
    if parsed.scheme != "https" or not parsed.hostname:
        raise CheckError("lookup URL must use public HTTPS")
    if parsed.username is not None or parsed.password is not None:
        raise CheckError("lookup URL must not contain credentials")
    if port is not None:
        raise CheckError("lookup URL must not include an explicit port")
    if parsed.fragment:
        raise CheckError("lookup URL must not include a fragment")
    return parsed


def validate_lookup_url(url: str) -> None:
    parsed = parsed_public_https_url(url)
    host = parsed.hostname.lower()
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    if host == "api.github.com":
        if not GITHUB_API_PATH.fullmatch(parsed.path):
            raise CheckError("GitHub API lookup URL has an unsupported path")
        if any(key not in {"page", "per_page"} for key, _ in query):
            raise CheckError("GitHub API lookup URL has unsupported query parameters")
        if any(not value.isdigit() for _, value in query):
            raise CheckError("GitHub API pagination values must be integers")
        return
    if query:
        raise CheckError("lookup URL must not include query parameters")
    if host == "raw.githubusercontent.com" and RAW_GITHUB_PATH.fullmatch(parsed.path):
        return
    if host == "registry.npmjs.org" and NPM_PATH.fullmatch(parsed.path):
        return
    if host == "pypi.org" and PYPI_PATH.fullmatch(parsed.path):
        return
    raise CheckError(f"lookup URL uses an unsupported public endpoint: {url}")


class ValidatingRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> Optional[urllib.request.Request]:
        validate_lookup_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def parse_version(value: str, prefix: str = "") -> tuple[int, int, int]:
    if prefix and not value.startswith(prefix):
        raise CheckError(f"{value!r} does not start with required prefix {prefix!r}")
    candidate = value[len(prefix) :]
    match = STABLE_VERSION.fullmatch(candidate)
    if not match:
        raise CheckError(f"{value!r} is not a stable three-part version")
    return tuple(int(part) for part in match.groups())


def version_in_policy(version: tuple[int, int, int], policy: dict[str, str]) -> bool:
    minimum = parse_version(policy["min_inclusive"])
    maximum = parse_version(policy["max_exclusive"])
    return minimum <= version < maximum


def extract_current(content: str, dependency: dict[str, Any]) -> str:
    extraction = dependency["extract"]
    matches = list(re.finditer(extraction["pattern"], content, re.MULTILINE))
    if len(matches) != 1:
        raise CheckError(
            f"extraction pattern matched {len(matches)} times; exactly one match is required"
        )
    if extraction["kind"] == "presence":
        return extraction["current"]
    if extraction["kind"] != "regex":
        raise CheckError(f"unsupported extraction kind {extraction['kind']!r}")
    try:
        return matches[0].group("version")
    except (IndexError, KeyError) as exc:
        raise CheckError("regex extraction requires a named 'version' group") from exc


class Fetcher:
    def __init__(self) -> None:
        self.cache: dict[str, Any] = {}
        self.opener = urllib.request.build_opener(ValidatingRedirectHandler())

    def get(self, url: str, *, as_json: bool) -> Any:
        validate_lookup_url(url)
        if url in self.cache:
            return self.cache[url]
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json, application/json",
                "User-Agent": "openshift-release-devcontainer-dependency-report/1",
            },
        )
        try:
            with self.opener.open(request, timeout=30) as response:
                validate_lookup_url(response.geturl())
                body = response.read().decode("utf-8")
        except (OSError, UnicodeError, urllib.error.HTTPError) as exc:
            raise CheckError(f"lookup failed for {url}: {exc}") from exc
        if as_json:
            try:
                value = json.loads(body)
            except json.JSONDecodeError as exc:
                raise CheckError(
                    f"lookup failed for {url}: invalid JSON: {exc}"
                ) from exc
        else:
            value = body
        self.cache[url] = value
        return value


def validate_repository_name(repository: str) -> None:
    if not REPOSITORY_NAME.fullmatch(repository):
        raise CheckError(f"invalid public GitHub repository name {repository!r}")


def resolve_github_revision(repository: str, ref: str, fetcher: Fetcher) -> str:
    validate_repository_name(repository)
    url = (
        f"https://api.github.com/repos/{repository}/commits/"
        f"{urllib.parse.quote(ref, safe='')}"
    )
    payload = fetcher.get(url, as_json=True)
    if not isinstance(payload, dict) or not isinstance(payload.get("sha"), str):
        raise CheckError(f"commit lookup for {repository}@{ref} returned no revision")
    revision = payload["sha"]
    if not COMMIT_SHA.fullmatch(revision):
        raise CheckError(
            f"commit lookup for {repository}@{ref} returned an invalid revision"
        )
    return revision


def job_spec_repository_revision(
    repository: str, requested_ref: str, repository_root: Path
) -> Optional[tuple[str, str]]:
    job_spec = os.environ.get("JOB_SPEC")
    if not job_spec:
        return None
    try:
        spec = json.loads(job_spec)
    except json.JSONDecodeError as exc:
        raise CheckError(f"JOB_SPEC is not valid JSON: {exc}") from exc
    if not isinstance(spec, dict):
        raise CheckError("JOB_SPEC root is not an object")
    primary_ref = spec.get("refs")
    if primary_ref is not None and not isinstance(primary_ref, dict):
        raise CheckError("JOB_SPEC refs is not a reference object")
    refs: list[dict[str, Any]] = []
    if isinstance(primary_ref, dict):
        refs.append(primary_ref)
    extra_refs = spec.get("extra_refs", [])
    if not isinstance(extra_refs, list) or not all(
        isinstance(ref, dict) for ref in extra_refs
    ):
        raise CheckError("JOB_SPEC extra_refs is not a list of references")
    refs.extend(extra_refs)
    matches = [
        ref for ref in refs if f"{ref.get('org')}/{ref.get('repo')}" == repository
    ]
    if len(matches) != 1:
        raise CheckError(
            f"JOB_SPEC has {len(matches)} references for selected repository {repository}; "
            "exactly one is required"
        )
    selected = matches[0]
    if selected.get("base_ref") != requested_ref:
        raise CheckError(
            f"JOB_SPEC selected {repository}@{selected.get('base_ref')}, "
            f"but policy requires {requested_ref}"
        )
    revision = selected.get("base_sha")
    if isinstance(revision, str) and COMMIT_SHA.fullmatch(revision):
        return revision, "job-spec-exact"
    if "base_sha" in selected:
        raise CheckError(
            f"JOB_SPEC has no valid exact revision for selected repository {repository}"
        )
    periodic_checkout = (
        spec.get("type") == "periodic"
        and spec.get("job") == PERIODIC_JOB_BY_REPOSITORY.get(repository)
        and primary_ref is None
        and len(extra_refs) == 1
        and selected is extra_refs[0]
        and "pulls" not in selected
        and repository_root == Path("/workspace")
    )
    if not periodic_checkout:
        raise CheckError(
            f"JOB_SPEC has no valid exact revision for selected repository {repository}"
        )
    return local_repository_revision(repository_root), "periodic-checkout-head"


def local_repository_revision(repository_root: Path) -> str:
    try:
        completed = subprocess.run(
            ["git", "-C", str(repository_root), "rev-parse", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise CheckError(
            f"could not determine local repository revision: {exc}"
        ) from exc
    revision = completed.stdout.strip()
    if completed.returncode != 0 or not COMMIT_SHA.fullmatch(revision):
        raise CheckError(
            "could not determine an exact revision for the local repository"
        )
    return revision


def local_inventory_source(repository_root: Path, file_paths: list[str]) -> str:
    try:
        completed = subprocess.run(
            [
                "git",
                "-C",
                str(repository_root),
                "status",
                "--porcelain=v1",
                "--untracked-files=all",
                "--",
                *sorted(set(file_paths)),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise CheckError(f"could not inspect the local working tree: {exc}") from exc
    if completed.returncode != 0:
        raise CheckError("could not inspect the local working tree")
    state = "dirty" if completed.stdout else "clean"
    return f"local-working-tree-{state}"


def selected_repository_revision(
    repository: str,
    requested_ref: str,
    repository_root: Path,
    explicit_revision: Optional[str],
    file_paths: list[str],
) -> tuple[str, str]:
    if explicit_revision and not COMMIT_SHA.fullmatch(explicit_revision):
        raise CheckError("--repository-revision must be a 40-character commit SHA")
    job_revision = job_spec_repository_revision(
        repository, requested_ref, repository_root
    )
    if job_revision:
        revision, inventory_source = job_revision
        if explicit_revision and explicit_revision != revision:
            raise CheckError("--repository-revision does not match JOB_SPEC")
        return revision, inventory_source
    local_revision = local_repository_revision(repository_root)
    if explicit_revision and explicit_revision != local_revision:
        raise CheckError("--repository-revision does not match local HEAD")
    return local_revision, local_inventory_source(repository_root, file_paths)


def rehearsal_policy_source(fetcher: Fetcher) -> Optional[tuple[str, str]]:
    job_spec = os.environ.get("JOB_SPEC")
    if not job_spec:
        return None
    try:
        spec = json.loads(job_spec)
    except json.JSONDecodeError as exc:
        raise CheckError(f"JOB_SPEC is not valid JSON: {exc}") from exc
    if not isinstance(spec, dict):
        raise CheckError("JOB_SPEC root is not an object")
    refs = spec.get("refs")
    if not isinstance(refs, dict):
        return None
    if f"{refs.get('org')}/{refs.get('repo')}" != POLICY_REPOSITORY:
        return None
    pulls = refs.get("pulls")
    if not isinstance(pulls, list) or not pulls or not isinstance(pulls[0], dict):
        raise CheckError("release rehearsal JOB_SPEC has no pull revision")
    pull = pulls[0]
    revision = pull.get("sha")
    if not isinstance(revision, str) or not COMMIT_SHA.fullmatch(revision):
        raise CheckError("release rehearsal JOB_SPEC has an invalid pull revision")
    number = pull.get("number")
    if not isinstance(number, int) or number <= 0:
        raise CheckError("release rehearsal JOB_SPEC has an invalid pull number")
    payload = fetcher.get(
        f"https://api.github.com/repos/{POLICY_REPOSITORY}/pulls/{number}",
        as_json=True,
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("head"), dict):
        raise CheckError("release pull lookup returned no head revision")
    head = payload["head"]
    head_repository = head.get("repo")
    if not isinstance(head_repository, dict):
        raise CheckError("release pull lookup returned no public head repository")
    repository = head_repository.get("full_name")
    if not isinstance(repository, str):
        raise CheckError("release pull lookup returned no public head repository")
    validate_repository_name(repository)
    if head.get("sha") != revision:
        raise CheckError("release pull head does not match the rehearsal revision")
    return repository, revision


def raw_github_url(repository: str, revision: str, path: str) -> str:
    validate_repository_name(repository)
    if not COMMIT_SHA.fullmatch(revision):
        raise CheckError(f"invalid GitHub revision for {repository}: {revision!r}")
    encoded_path = "/".join(
        urllib.parse.quote(part, safe="") for part in path.split("/")
    )
    return f"https://raw.githubusercontent.com/{repository}/{revision}/{encoded_path}"


def github_page_url(url: str, kind: str, page: int) -> tuple[str, int]:
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except ValueError as exc:
        raise CheckError(f"invalid GitHub source URL {url!r}: {exc}") from exc
    if parsed.scheme != "https" or parsed.hostname != "api.github.com":
        raise CheckError("GitHub source URL must use https://api.github.com")
    if parsed.username is not None or parsed.password is not None:
        raise CheckError("GitHub source URL must be public HTTPS without credentials")
    if port is not None:
        raise CheckError("GitHub source URL must not include an explicit port")
    if parsed.fragment:
        raise CheckError("GitHub source URL must not include a fragment")
    expected_endpoint = {
        "github_releases": "releases",
        "github_tags": "tags",
    }.get(kind)
    path_parts = parsed.path.strip("/").split("/")
    if expected_endpoint is None:
        raise CheckError(f"invalid GitHub source kind {kind!r}")
    if len(path_parts) != 4 or path_parts[0] != "repos":
        raise CheckError(f"invalid GitHub {kind} API path")
    if not path_parts[1] or not path_parts[2] or path_parts[3] != expected_endpoint:
        raise CheckError(f"invalid GitHub {kind} API path")
    query = urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
    unsupported_parameters = {key for key, _ in query} - {"page", "per_page"}
    if unsupported_parameters:
        raise CheckError(
            "GitHub source URL has unsupported query parameters: "
            + ", ".join(sorted(unsupported_parameters))
        )
    per_page_values = [value for key, value in query if key == "per_page"]
    page_values = [value for key, value in query if key == "page"]
    if len(per_page_values) > 1 or len(page_values) > 1:
        raise CheckError("GitHub source URL has duplicate pagination parameters")
    try:
        per_page = int(per_page_values[0]) if per_page_values else 30
    except ValueError as exc:
        raise CheckError("GitHub source URL per_page must be an integer") from exc
    if not 1 <= per_page <= 100:
        raise CheckError("GitHub source URL per_page must be between 1 and 100")
    if page_values and page_values[0] != "1":
        raise CheckError("GitHub source URL pagination must start at page 1")
    if page == 1:
        return url, per_page
    query = [(key, value) for key, value in query if key != "page"]
    query.append(("page", str(page)))
    return urllib.parse.urlunsplit(
        parsed._replace(query=urllib.parse.urlencode(query))
    ), per_page


def github_items(source: dict[str, Any], fetcher: Fetcher) -> list[dict[str, Any]]:
    url = source["url"]
    kind = source["kind"]
    _, per_page = github_page_url(url, kind, 1)
    items: list[dict[str, Any]] = []
    for page in range(1, GITHUB_PAGE_LIMIT + 1):
        page_url, _ = github_page_url(url, kind, page)
        payload = fetcher.get(page_url, as_json=True)
        if not isinstance(payload, list):
            raise CheckError(
                f"GitHub {source['kind']} page {page} response is not a list"
            )
        for index, item in enumerate(payload):
            if not isinstance(item, dict):
                raise CheckError(
                    f"GitHub {source['kind']} page {page} item {index} is not an object"
                )
            items.append(item)
        if len(payload) < per_page:
            return items
    raise CheckError(
        f"GitHub pagination reached the safety limit of {GITHUB_PAGE_LIMIT} pages; "
        "refusing to select from partial version data"
    )


def source_versions(source: dict[str, Any], fetcher: Fetcher) -> list[str]:
    kind = source["kind"]
    if kind == "github_releases":
        payload = github_items(source, fetcher)
        return [
            item["tag_name"]
            for item in payload
            if not item.get("draft")
            and not item.get("prerelease")
            and isinstance(item.get("tag_name"), str)
            and item["tag_name"]
        ]
    if kind == "github_tags":
        payload = github_items(source, fetcher)
        return [
            item["name"]
            for item in payload
            if isinstance(item.get("name"), str) and item["name"]
        ]
    payload = fetcher.get(source["url"], as_json=True)
    if kind == "npm":
        releases = payload.get("versions")
        if not isinstance(releases, dict):
            raise CheckError("npm response has no version map")
        return [
            version
            for version, metadata in releases.items()
            if isinstance(metadata, dict) and not metadata.get("deprecated")
        ]
    if kind == "pypi":
        releases = payload.get("releases")
        if not isinstance(releases, dict):
            raise CheckError("pypi response has no version map")
        return [
            version
            for version, files in releases.items()
            if isinstance(files, list)
            and files
            and any(isinstance(item, dict) and not item.get("yanked") for item in files)
        ]
    raise CheckError(f"unsupported source kind {kind!r}")


def latest_allowed(
    source: dict[str, Any], policy: dict[str, str], fetcher: Fetcher
) -> tuple[str, tuple[int, int, int]]:
    prefix = source.get("tag_prefix", "")
    candidates: list[tuple[tuple[int, int, int], str]] = []
    for value in source_versions(source, fetcher):
        try:
            parsed = parse_version(value, prefix)
        except CheckError:
            continue
        if version_in_policy(parsed, policy):
            candidates.append((parsed, value.removeprefix(prefix)))
    if not candidates:
        raise CheckError(
            "version source returned no stable version inside the policy range"
        )
    parsed, rendered = max(candidates)
    return rendered, parsed


def validate_source_url(source_name: str, source: dict[str, Any]) -> None:
    kind = source.get("kind")
    url = source.get("url")
    if not isinstance(kind, str) or not isinstance(url, str):
        raise CheckError(f"source {source_name!r} requires kind and URL strings")
    validate_lookup_url(url)
    parsed = urllib.parse.urlsplit(url)
    if kind in {"github_releases", "github_tags"}:
        github_page_url(url, kind, 1)
        return
    expected_host = {"npm": "registry.npmjs.org", "pypi": "pypi.org"}.get(kind)
    if expected_host is None:
        raise CheckError(f"source {source_name!r} has unsupported kind {kind!r}")
    if parsed.hostname != expected_host:
        raise CheckError(
            f"source {source_name!r} kind {kind!r} requires host {expected_host}"
        )


def validate_config(config: dict[str, Any]) -> None:
    if config.get("schema_version") != 1:
        raise CheckError("only config schema_version 1 is supported")
    sources = config.get("sources", {})
    if not isinstance(sources, dict):
        raise CheckError("config sources must be an object")
    for source_name, source in sources.items():
        if not isinstance(source_name, str) or not isinstance(source, dict):
            raise CheckError("each source requires a string name and object value")
        validate_source_url(source_name, source)
    repositories = config.get("repositories")
    if not isinstance(repositories, list) or not repositories:
        raise CheckError("config must contain at least one repository")
    seen_repositories: set[str] = set()
    for repository in repositories:
        if not isinstance(repository, dict):
            raise CheckError("each repository declaration must be an object")
        repository_name = repository.get("name")
        if not repository_name or not repository.get("ref"):
            raise CheckError("each repository requires name and ref")
        if repository_name in seen_repositories:
            raise CheckError(f"duplicate repository declaration: {repository_name}")
        seen_repositories.add(repository_name)
        dependencies = repository.get("dependencies")
        if not isinstance(dependencies, list) or not dependencies:
            raise CheckError(f"{repository_name}: at least one dependency is required")
        seen_dependencies: set[tuple[str, str]] = set()
        for dependency in dependencies:
            if not isinstance(dependency, dict):
                raise CheckError(
                    f"{repository_name}: each dependency must be an object"
                )
            dependency_name = dependency.get("name")
            file_path = dependency.get("file")
            if not dependency_name or not file_path or not dependency.get("rationale"):
                raise CheckError(
                    f"{repository_name}: each dependency requires name, file, and rationale"
                )
            identity = (file_path, dependency_name)
            if identity in seen_dependencies:
                raise CheckError(
                    f"{repository_name}: duplicate dependency declaration: "
                    f"{file_path} {dependency_name}"
                )
            seen_dependencies.add(identity)
            extraction = dependency.get("extract")
            if not isinstance(extraction, dict) or not extraction.get("pattern"):
                raise CheckError(
                    f"{repository_name}/{dependency_name}: extraction requires a pattern"
                )
            if extraction.get("kind") not in {"presence", "regex"}:
                raise CheckError(
                    f"{repository_name}/{dependency_name}: invalid extraction kind"
                )
            if extraction["kind"] == "presence" and not extraction.get("current"):
                raise CheckError(
                    f"{repository_name}/{dependency_name}: presence extraction requires current"
                )
            classification = dependency.get("classification")
            if classification not in CLASSIFICATIONS:
                raise CheckError(
                    f"{repository_name}/{dependency_name}: invalid classification"
                )
            if classification == "pinned":
                source = sources.get(dependency.get("source"))
                policy = dependency.get("policy")
                if (
                    not isinstance(source, dict)
                    or not source.get("kind")
                    or not source.get("url")
                ):
                    raise CheckError(
                        f"{repository_name}/{dependency_name}: pinned entries require a valid source"
                    )
                if (
                    not isinstance(policy, dict)
                    or not isinstance(policy.get("min_inclusive"), str)
                    or not isinstance(policy.get("max_exclusive"), str)
                ):
                    raise CheckError(
                        f"{repository_name}/{dependency_name}: pinned entries require policy bounds"
                    )
                minimum = parse_version(policy["min_inclusive"])
                maximum = parse_version(policy["max_exclusive"])
                if minimum >= maximum:
                    raise CheckError(
                        f"{repository_name}/{dependency_name}: policy range must be non-empty"
                    )
            elif dependency.get("source") or dependency.get("policy"):
                raise CheckError(
                    f"{repository_name}/{dependency_name}: only pinned entries may define source/policy"
                )
            if classification == "repo-coupled" and not dependency.get("authority"):
                raise CheckError(
                    f"{repository_name}/{dependency_name}: repo-coupled entries require authority"
                )
            if (
                classification != "repo-coupled"
                and classification != "pinned"
                and not dependency.get("version_source")
            ):
                raise CheckError(
                    f"{repository_name}/{dependency_name}: {classification} entries require version_source"
                )


def selected_config(
    config: dict[str, Any],
    repository_name: str,
    repository_root: Path,
    explicit_revision: Optional[str],
) -> tuple[dict[str, Any], str, str, str]:
    validate_config(config)
    matches = [
        repository
        for repository in config["repositories"]
        if repository["name"] == repository_name
    ]
    if len(matches) != 1:
        raise CheckError(
            f"selected repository {repository_name!r} does not have exactly one policy entry"
        )
    repository = dict(matches[0])
    requested_ref = repository["ref"]
    file_paths = [dependency["file"] for dependency in repository["dependencies"]]
    revision, inventory_source = selected_repository_revision(
        repository_name,
        requested_ref,
        repository_root,
        explicit_revision,
        file_paths,
    )
    repository["revision"] = revision
    return (
        {**config, "repositories": [repository]},
        requested_ref,
        revision,
        inventory_source,
    )


def repository_file(repository_root: Path, file_path: str) -> Path:
    relative = Path(file_path)
    if relative.is_absolute() or ".." in relative.parts:
        raise CheckError(f"repository file must be a safe relative path: {file_path!r}")
    try:
        root = repository_root.resolve()
        candidate = (root / relative).resolve()
    except (OSError, RuntimeError) as exc:
        raise CheckError(
            f"could not resolve local repository file {file_path!r}: {exc}"
        ) from exc
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise CheckError(
            f"repository file escapes the local workspace: {file_path!r}"
        ) from exc
    return candidate


def ensure_output_outside_repository(output_dir: Path, repository_root: Path) -> None:
    try:
        root = repository_root.resolve()
        output = output_dir.resolve()
    except (OSError, RuntimeError) as exc:
        raise CheckError(
            f"could not resolve repository or output directory: {exc}"
        ) from exc
    try:
        output.relative_to(root)
    except ValueError:
        return
    raise CheckError(
        f"output directory {output} is inside target repository {root}; refusing to write"
    )


def atomic_write_text(destination: Path, content: str) -> None:
    temporary: Optional[Path] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(content)
        temporary.chmod(0o644)
        temporary.replace(destination)
    except BaseException:
        if temporary is not None:
            try:
                temporary.unlink()
            except OSError:
                pass
        raise


def check(
    config: dict[str, Any], fetcher: Fetcher, repository_root: Path
) -> list[dict[str, Any]]:
    if not repository_root.is_dir():
        raise CheckError(
            f"target repository workspace does not exist: {repository_root}"
        )
    results: list[dict[str, Any]] = []
    source_cache: dict[tuple[str, str, str], tuple[str, tuple[int, int, int]]] = {}
    for repository in config["repositories"]:
        file_cache: dict[str, Union[str, CheckError]] = {}
        for dependency in repository["dependencies"]:
            file_path = dependency["file"]
            row: dict[str, Any] = {
                "repository": repository["name"],
                "ref": repository["ref"],
                "revision": repository["revision"],
                "file": file_path,
                "dependency": dependency["name"],
                "classification": dependency["classification"],
                "current": None,
                "proposed": None,
                "version_source": dependency.get("version_source")
                or dependency.get("authority"),
                "authority": dependency.get("authority"),
                "status": dependency["classification"],
                "rationale": dependency["rationale"],
                "error": None,
            }
            try:
                if file_path not in file_cache:
                    try:
                        file_cache[file_path] = repository_file(
                            repository_root, file_path
                        ).read_text(encoding="utf-8")
                    except (CheckError, OSError, UnicodeError) as exc:
                        file_cache[file_path] = CheckError(
                            f"could not read local repository file {file_path}: {exc}"
                        )
                content = file_cache[file_path]
                if isinstance(content, CheckError):
                    raise content
                current = extract_current(content, dependency)
                row["current"] = current
                if dependency["classification"] == "pinned":
                    source = config["sources"][dependency["source"]]
                    row["version_source"] = source["url"]
                    current_parsed = parse_version(
                        current, dependency.get("current_prefix", "")
                    )
                    if not version_in_policy(current_parsed, dependency["policy"]):
                        raise CheckError(
                            "current version is outside the explicit policy range"
                        )
                    cache_key = (
                        dependency["source"],
                        dependency["policy"]["min_inclusive"],
                        dependency["policy"]["max_exclusive"],
                    )
                    if cache_key not in source_cache:
                        source_cache[cache_key] = latest_allowed(
                            source, dependency["policy"], fetcher
                        )
                    proposed, proposed_parsed = source_cache[cache_key]
                    if proposed_parsed > current_parsed:
                        row["proposed"] = proposed
                        row["status"] = "update_available"
                        row["rationale"] = (
                            f"{dependency['rationale']} Newest stable version inside "
                            f"[{dependency['policy']['min_inclusive']}, "
                            f"{dependency['policy']['max_exclusive']}) is {proposed}."
                        )
                    else:
                        row["proposed"] = current
                        row["status"] = "no_change"
                        row["rationale"] = (
                            f"{dependency['rationale']} No newer stable version was found "
                            "inside the explicit policy range; downgrades are never proposed."
                        )
            except (
                AttributeError,
                CheckError,
                KeyError,
                TypeError,
                ValueError,
                json.JSONDecodeError,
                re.error,
            ) as exc:
                row["status"] = "error"
                row["proposed"] = None
                row["error"] = str(exc)
                row["rationale"] = f"Check failed: {exc}"
            results.append(row)
    return results


def write_reports(
    results: list[dict[str, Any]],
    output_dir: Path,
    *,
    policy_repository: str,
    policy_revision: str,
    repository: str,
    requested_ref: str,
    repository_revision: str,
    inventory_source: str,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    document = {
        "schema_version": 1,
        "generated_at": generated_at,
        "policy": {
            "repository": policy_repository,
            "path": POLICY_PATH,
            "revision": policy_revision,
        },
        "repository": {
            "name": repository,
            "requested_ref": requested_ref,
            "revision": repository_revision,
            "inventory_source": inventory_source,
        },
        "results": results,
    }
    atomic_write_text(
        output_dir / "devcontainer-dependency-report.json",
        json.dumps(document, indent=2, sort_keys=True) + "\n",
    )
    counts: dict[str, int] = {}
    for row in results:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    lines = [
        "# Devcontainer dependency report",
        "",
        f"Generated: {generated_at}",
        "",
        f"Policy revision: `{policy_repository}@{policy_revision}`",
        "",
        f"Repository revision: `{repository}@{repository_revision}` (requested `{requested_ref}`)",
        "",
        f"Inventory source: `{inventory_source}`",
        "",
        "This report is advisory. It does not claim compatibility or modify dependencies.",
        "",
        "## Summary",
        "",
    ]
    lines.extend(f"- {key}: {counts[key]}" for key in sorted(counts))
    lines.extend(
        [
            "",
            "## Inventory",
            "",
            "| Repository | File | Dependency | Class | Current | Proposed | Status | Version source / authority | Rationale |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
    )
    for row in results:
        values = [
            row["repository"],
            row["file"],
            row["dependency"],
            row["classification"],
            row["current"] or "—",
            row["proposed"] or "—",
            row["status"],
            row["version_source"] or row["authority"] or "—",
            row["error"] or row["rationale"],
        ]
        lines.append(
            "| "
            + " | ".join(
                str(value).replace("|", "\\|").replace("\n", " ") for value in values
            )
            + " |"
        )
    atomic_write_text(
        output_dir / "devcontainer-dependency-report.md", "\n".join(lines) + "\n"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_output = os.environ.get(
        "ARTIFACT_DIR", "artifacts/devcontainer-dependency-report"
    )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository",
        default=os.environ.get("DEVCONTAINER_DEPENDENCY_REPOSITORY"),
        help="one public repository named in the shared policy",
    )
    parser.add_argument(
        "--repository-root",
        default=os.environ.get("DEVCONTAINER_DEPENDENCY_ROOT", "/workspace"),
        type=Path,
        help="local checkout of the selected repository (default: /workspace)",
    )
    parser.add_argument(
        "--repository-revision",
        help="exact revision assertion; must match JOB_SPEC or local HEAD",
    )
    parser.add_argument("--config", type=Path, help="use a local policy file")
    parser.add_argument(
        "--policy-revision",
        help="revision recorded for a local policy file (required with --config)",
    )
    parser.add_argument("--output-dir", default=default_output, type=Path)
    parser.add_argument(
        "--fail-on-errors", action=argparse.BooleanOptionalAction, default=True
    )
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    fetcher = Fetcher()
    try:
        if not args.repository:
            raise CheckError(
                "--repository or DEVCONTAINER_DEPENDENCY_REPOSITORY is required"
            )
        policy_source_repository = POLICY_REPOSITORY
        if args.config:
            if not args.policy_revision:
                raise CheckError("--policy-revision is required with --config")
            if not COMMIT_SHA.fullmatch(args.policy_revision):
                raise CheckError("--policy-revision must be a 40-character commit SHA")
            config_text = args.config.read_text(encoding="utf-8")
            policy_revision = args.policy_revision
        else:
            if args.policy_revision:
                raise CheckError("--policy-revision may only be used with --config")
            rehearsal_source = rehearsal_policy_source(fetcher)
            if rehearsal_source:
                policy_source_repository, policy_revision = rehearsal_source
            else:
                policy_revision = resolve_github_revision(
                    POLICY_REPOSITORY, POLICY_REF, fetcher
                )
            config_text = fetcher.get(
                raw_github_url(policy_source_repository, policy_revision, POLICY_PATH),
                as_json=False,
            )
        config = json.loads(config_text)
        if not isinstance(config, dict):
            raise CheckError("policy document root must be an object")
        config, requested_ref, repository_revision, inventory_source = selected_config(
            config,
            args.repository,
            args.repository_root,
            args.repository_revision,
        )
        ensure_output_outside_repository(args.output_dir, args.repository_root)
        results = check(config, fetcher, args.repository_root)
    except (OSError, json.JSONDecodeError, CheckError) as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2
    write_reports(
        results,
        args.output_dir,
        policy_repository=policy_source_repository,
        policy_revision=policy_revision,
        repository=args.repository,
        requested_ref=requested_ref,
        repository_revision=repository_revision,
        inventory_source=inventory_source,
    )
    for row in results:
        suffix = f": {row['error']}" if row["error"] else ""
        print(
            f"{row['repository']} {row['file']} {row['dependency']}: "
            f"{row['status']}{suffix}"
        )
    errors = sum(row["status"] == "error" for row in results)
    print(f"wrote {len(results)} inventory rows to {args.output_dir}; errors={errors}")
    return 1 if errors and args.fail_on_errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
