#!/usr/bin/env python3
"""Report public devcontainer dependency versions without changing repositories."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


STABLE_COMPONENT = r"(?:0|[1-9]\d*)"
STABLE_VERSION = re.compile(
    rf"^({STABLE_COMPONENT})\.({STABLE_COMPONENT})\.({STABLE_COMPONENT})$"
)
CLASSIFICATIONS = {"pinned", "floating", "repo-coupled", "manual", "unsupported"}
GITHUB_PAGE_LIMIT = 10


class CheckError(RuntimeError):
    """An expected lookup, extraction, or policy failure."""


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
    def __init__(self, responses: dict[str, Any] | None = None) -> None:
        self.responses = responses
        self.cache: dict[str, Any] = {}

    def get(self, url: str, *, as_json: bool) -> Any:
        if url in self.cache:
            return self.cache[url]
        if self.responses is not None:
            if url not in self.responses:
                raise CheckError(f"no recorded response for {url}")
            value = self.responses[url]
            if isinstance(value, dict) and "__error__" in value:
                raise CheckError(f"lookup failed for {url}: {value['__error__']}")
        else:
            request = urllib.request.Request(
                url,
                headers={
                    "Accept": "application/vnd.github+json, application/json",
                    "User-Agent": "openshift-release-devcontainer-dependency-report/1",
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    body = response.read().decode("utf-8")
            except (OSError, UnicodeError, urllib.error.HTTPError) as exc:
                raise CheckError(f"lookup failed for {url}: {exc}") from exc
            if as_json:
                try:
                    value = json.loads(body)
                except json.JSONDecodeError as exc:
                    raise CheckError(f"lookup failed for {url}: invalid JSON: {exc}") from exc
            else:
                value = body
        self.cache[url] = value
        return value


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
    if port not in {None, 443}:
        raise CheckError("GitHub source URL must not use a nonstandard port")
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
    return urllib.parse.urlunsplit(parsed._replace(query=urllib.parse.urlencode(query))), per_page


def github_items(source: dict[str, Any], fetcher: Fetcher) -> list[dict[str, Any]]:
    url = source["url"]
    kind = source["kind"]
    _, per_page = github_page_url(url, kind, 1)
    items: list[dict[str, Any]] = []
    for page in range(1, GITHUB_PAGE_LIMIT + 1):
        page_url, _ = github_page_url(url, kind, page)
        payload = fetcher.get(page_url, as_json=True)
        if not isinstance(payload, list):
            raise CheckError(f"GitHub {source['kind']} page {page} response is not a list")
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
        raise CheckError("version source returned no stable version inside the policy range")
    parsed, rendered = max(candidates)
    return rendered, parsed


def validate_config(config: dict[str, Any]) -> None:
    if config.get("schema_version") != 1:
        raise CheckError("only config schema_version 1 is supported")
    sources = config.get("sources", {})
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
                raise CheckError(f"{repository_name}: each dependency must be an object")
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
                if not isinstance(source, dict) or not source.get("kind") or not source.get("url"):
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
            if classification != "repo-coupled" and classification != "pinned" and not dependency.get(
                "version_source"
            ):
                raise CheckError(
                    f"{repository_name}/{dependency_name}: {classification} entries require version_source"
                )


def check(config: dict[str, Any], fetcher: Fetcher) -> list[dict[str, Any]]:
    validate_config(config)
    results: list[dict[str, Any]] = []
    source_cache: dict[tuple[str, str, str], tuple[str, tuple[int, int, int]]] = {}
    for repository in config["repositories"]:
        raw_base = repository.get(
            "raw_base", f"https://raw.githubusercontent.com/{repository['name']}/{repository['ref']}"
        )
        file_cache: dict[str, str | CheckError] = {}
        for dependency in repository["dependencies"]:
            file_path = dependency["file"]
            row: dict[str, Any] = {
                "repository": repository["name"],
                "ref": repository["ref"],
                "file": file_path,
                "dependency": dependency["name"],
                "classification": dependency["classification"],
                "current": None,
                "proposed": None,
                "version_source": dependency.get("version_source") or dependency.get("authority"),
                "authority": dependency.get("authority"),
                "status": dependency["classification"],
                "rationale": dependency["rationale"],
                "error": None,
            }
            try:
                if file_path not in file_cache:
                    try:
                        file_cache[file_path] = fetcher.get(
                            f"{raw_base}/{file_path}", as_json=False
                        )
                    except CheckError as exc:
                        file_cache[file_path] = exc
                content = file_cache[file_path]
                if isinstance(content, CheckError):
                    raise content
                current = extract_current(content, dependency)
                row["current"] = current
                if dependency["classification"] == "pinned":
                    source = config["sources"][dependency["source"]]
                    row["version_source"] = source["url"]
                    current_parsed = parse_version(current, dependency.get("current_prefix", ""))
                    if not version_in_policy(current_parsed, dependency["policy"]):
                        raise CheckError("current version is outside the explicit policy range")
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


def write_reports(results: list[dict[str, Any]], output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    document = {"schema_version": 1, "generated_at": generated_at, "results": results}
    (output_dir / "devcontainer-dependency-report.json").write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    counts: dict[str, int] = {}
    for row in results:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    lines = [
        "# Devcontainer dependency report",
        "",
        f"Generated: {generated_at}",
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
    (output_dir / "devcontainer-dependency-report.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8"
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    default_config = os.environ.get(
        "DEVCONTAINER_DEPENDENCY_CONFIG",
        "ci-operator/step-registry/openshift/devcontainer-dependency-report/"
        "openshift-devcontainer-dependency-report-config.md",
    )
    default_output = os.environ.get("ARTIFACT_DIR", "artifacts/devcontainer-dependency-report")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=default_config, type=Path)
    parser.add_argument("--output-dir", default=default_output, type=Path)
    parser.add_argument("--responses-file", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--fail-on-errors", action=argparse.BooleanOptionalAction, default=True)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        config = json.loads(args.config.read_text(encoding="utf-8"))
        responses = (
            json.loads(args.responses_file.read_text(encoding="utf-8"))
            if args.responses_file
            else None
        )
        results = check(config, Fetcher(responses))
    except (OSError, json.JSONDecodeError, CheckError) as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2
    write_reports(results, args.output_dir)
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
