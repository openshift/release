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
import urllib.request
from pathlib import Path
from typing import Any


STABLE_VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
CLASSIFICATIONS = {"pinned", "floating", "repo-coupled", "manual", "unsupported"}


class CheckError(RuntimeError):
    """An expected lookup, extraction, or policy failure."""


def parse_version(value: str, prefix: str = "") -> tuple[int, int, int]:
    candidate = value.removeprefix(prefix)
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
            value = json.loads(body) if as_json else body
        self.cache[url] = value
        return value


def source_versions(source: dict[str, Any], fetcher: Fetcher) -> list[str]:
    payload = fetcher.get(source["url"], as_json=True)
    kind = source["kind"]
    if kind == "github_releases":
        if not isinstance(payload, list):
            raise CheckError("GitHub releases response is not a list")
        return [
            item["tag_name"]
            for item in payload
            if not item.get("draft") and not item.get("prerelease") and item.get("tag_name")
        ]
    if kind == "github_tags":
        if not isinstance(payload, list):
            raise CheckError("GitHub tags response is not a list")
        return [item["name"] for item in payload if item.get("name")]
    if kind in {"npm", "pypi"}:
        releases = payload.get("versions") if kind == "npm" else payload.get("releases")
        if not isinstance(releases, dict):
            raise CheckError(f"{kind} response has no version map")
        return list(releases)
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
    for repository in config.get("repositories", []):
        for dependency in repository.get("dependencies", []):
            classification = dependency.get("classification")
            if classification not in CLASSIFICATIONS:
                raise CheckError(
                    f"{repository.get('name')}/{dependency.get('name')}: invalid classification"
                )
            if classification == "pinned":
                if dependency.get("source") not in sources or "policy" not in dependency:
                    raise CheckError(
                        f"{repository['name']}/{dependency['name']}: pinned entries require source and policy"
                    )
                version_in_policy((0, 0, 0), dependency["policy"])
            elif dependency.get("source") or dependency.get("policy"):
                raise CheckError(
                    f"{repository['name']}/{dependency['name']}: only pinned entries may define source/policy"
                )
            if classification == "repo-coupled" and not dependency.get("authority"):
                raise CheckError(
                    f"{repository['name']}/{dependency['name']}: repo-coupled entries require authority"
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
                "version_source": dependency.get("version_source"),
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
