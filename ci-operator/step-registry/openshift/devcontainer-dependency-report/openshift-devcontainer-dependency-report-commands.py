#!/usr/bin/env python3
"""Report public devcontainer and agentic CI dependencies without changing them."""

# Keep annotations and UTC handling compatible with Python 3.9.
# ruff: noqa: UP007, UP017, UP045

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import http.client
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
COMMIT_SHA = re.compile(r"^[0-9a-f]{40}$")
REPOSITORY_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
NPM_PACKAGE = re.compile(r"^(?:[A-Za-z0-9_.~-]+|@[A-Za-z0-9_.~-]+/[A-Za-z0-9_.~-]+)$")
PYPI_PACKAGE = re.compile(r"^[A-Za-z0-9_.-]+$")
CLASSIFICATIONS = {"pinned", "floating", "repo-coupled", "manual"}
SCOPES = {"devcontainer", "agentic-ci"}

SOURCES: dict[str, dict[str, str]] = {
    "agentic-ci": {"kind": "pypi", "package": "agentic-ci"},
    "apm-cli": {"kind": "pypi", "package": "apm-cli"},
    "delve": {
        "kind": "git_tags",
        "repository": "go-delve/delve",
        "tag_prefix": "v",
    },
    "gh": {"kind": "git_tags", "repository": "cli/cli", "tag_prefix": "v"},
    "golangci-lint": {
        "kind": "git_tags",
        "repository": "golangci/golangci-lint",
        "tag_prefix": "v",
    },
    "gopls": {
        "kind": "git_tags",
        "repository": "golang/tools",
        "tag_prefix": "gopls/v",
    },
    "gotestsum": {
        "kind": "git_tags",
        "repository": "gotestyourself/gotestsum",
        "tag_prefix": "v",
    },
    "playwright": {"kind": "npm", "package": "playwright"},
    "prometheus": {
        "kind": "git_tags",
        "repository": "prometheus/prometheus",
        "tag_prefix": "v",
    },
    "staticcheck": {
        "kind": "git_tags",
        "repository": "dominikh/go-tools",
        "tag_prefix": "v",
    },
    "uv": {"kind": "pypi", "package": "uv"},
}

DEPENDENCIES: dict[str, dict[str, Any]] = {
    "agentic-ci": {
        "name": "agentic-ci",
        "classification": "pinned",
        "scope": "agentic-ci",
        "source_repository": "openshift/release",
        "files": {
            "openshift/sippy": (
                "ci-operator/config/openshift/sippy/openshift-sippy-main__agentic.yaml"
            ),
            "openshift/origin": (
                "ci-operator/config/openshift/origin/"
                "openshift-origin-main__agentic.yaml"
            ),
            "openshift-eng/ship-status-dash": (
                "ci-operator/config/openshift-eng/ship-status-dash/"
                "openshift-eng-ship-status-dash-main__agentic.yaml"
            ),
        },
        "pattern": (
            r"python3 -m pip install --no-cache-dir agentic-ci=="
            r"(?P<version>[^\s\\]+)(?=\s|$)"
        ),
        "source": "agentic-ci",
        "policy": {"min_inclusive": "0.5.0", "max_exclusive": "0.6.0"},
        "authority": "openshift/release agentic image configuration owners",
        "update_group": "openshift/release-agentic-ci",
        "rationale": (
            "All three agentic image pins are owned by openshift/release and must be "
            "updated together in one release-repository change. Report only a stable "
            "0.5.x candidate; maintainers must validate the shared agentic workflows."
        ),
    },
    "codex-version": {
        "name": "codex-version",
        "classification": "repo-coupled",
        "scope": "agentic-ci",
        "source_repository": "openshift/release",
        "file": (
            "ci-operator/step-registry/openshift/agentic/trt/init-model/"
            "openshift-agentic-trt-init-model-commands.sh"
        ),
        "pattern": r'^    local version="(?P<version>[^"\s]+)"$',
        "authority": "openshift/release init-model owners",
        "update_group": "openshift/release-agentic-ci",
        "rationale": (
            "The Codex version and both architecture-specific SHA256 values form one "
            "verified install set and require an intentional, checksum-backed change; "
            "no independent version proposal is made."
        ),
    },
    "codex-sha256-x86_64": {
        "name": "codex-sha256-x86_64",
        "classification": "repo-coupled",
        "scope": "agentic-ci",
        "source_repository": "openshift/release",
        "file": (
            "ci-operator/step-registry/openshift/agentic/trt/init-model/"
            "openshift-agentic-trt-init-model-commands.sh"
        ),
        "pattern": (
            r'^            sha="(?P<version>[0-9a-f]{64})"\n'
            r"            ;;(?=\n        aarch64\))"
        ),
        "authority": "openshift/release init-model owners",
        "update_group": "openshift/release-agentic-ci",
        "rationale": (
            "The x86_64 archive checksum is coupled to the selected Codex release and "
            "must be reviewed with the version and aarch64 checksum."
        ),
    },
    "codex-sha256-aarch64": {
        "name": "codex-sha256-aarch64",
        "classification": "repo-coupled",
        "scope": "agentic-ci",
        "source_repository": "openshift/release",
        "file": (
            "ci-operator/step-registry/openshift/agentic/trt/init-model/"
            "openshift-agentic-trt-init-model-commands.sh"
        ),
        "pattern": (
            r"        aarch64\)\n"
            r'            arch="aarch64"\n'
            r'            sha="(?P<version>[0-9a-f]{64})"'
        ),
        "authority": "openshift/release init-model owners",
        "update_group": "openshift/release-agentic-ci",
        "rationale": (
            "The aarch64 archive checksum is coupled to the selected Codex release and "
            "must be reviewed with the version and x86_64 checksum."
        ),
    },
    "claude-installer": {
        "name": "claude-installer",
        "classification": "floating",
        "scope": "agentic-ci",
        "source_repository": "openshift/release",
        "file": (
            "ci-operator/step-registry/openshift/agentic/trt/jira-solver/"
            "openshift-agentic-trt-jira-solver-commands.sh"
        ),
        "pattern": (
            r"curl -fsSL --retry 3 --retry-delay 5 "
            r"(?P<version>https://claude\.ai/install\.sh) \| sh"
        ),
        "version_source": "https://claude.ai/install.sh",
        "authority": "openshift/release jira-solver owners",
        "update_group": "openshift/release-agentic-ci",
        "rationale": (
            "The normal non-evaluation solver intentionally runs the unversioned public "
            "installer URL, so it is floating and receives no invented pin or proposal."
        ),
    },
    "fedora-base": {
        "name": "fedora-base",
        "classification": "manual",
        "file": ".devcontainer/Dockerfile",
        "pattern": r"^FROM registry\.fedoraproject\.org/fedora:(?P<version>[0-9]+)$",
        "version_source": "registry.fedoraproject.org/fedora tags",
        "rationale": (
            "Base-image changes also change the distribution toolchain and require "
            "target-repository compatibility validation; no automatic proposal is made."
        ),
    },
    "golangci-lint": {
        "name": "golangci-lint",
        "classification": "pinned",
        "file": ".devcontainer/Dockerfile",
        "pattern": r"^ARG GOLANGCI_LINT_VERSION=(?P<version>\S+)$",
        "source": "golangci-lint",
        "policy": {"min_inclusive": "2.0.0", "max_exclusive": "3.0.0"},
        "rationale": (
            "Report a stable 2.x candidate only; maintainers must validate the lint "
            "configuration and repository code."
        ),
    },
    "github-cli": {
        "name": "github-cli",
        "classification": "pinned",
        "file": ".devcontainer/Dockerfile",
        "pattern": r"^ARG GH_VERSION=(?P<version>\S+)$",
        "source": "gh",
        "policy": {"min_inclusive": "2.0.0", "max_exclusive": "3.0.0"},
        "rationale": "Report a stable 2.x tag only; this is not a compatibility claim.",
    },
    "gotestsum-pinned": {
        "name": "gotestsum",
        "classification": "pinned",
        "file": ".devcontainer/Dockerfile",
        "pattern": (
            r"(?P<quote>[\"']?)gotest\.tools/gotestsum@v"
            r"(?P<version>[^\"'\s]+)(?P=quote)(?=$|\s)"
        ),
        "source": "gotestsum",
        "policy": {"min_inclusive": "1.0.0", "max_exclusive": "2.0.0"},
        "rationale": (
            "Report a stable 1.x tag only; maintainers must validate repository tests."
        ),
    },
    "gotestsum-floating": {
        "name": "gotestsum",
        "classification": "floating",
        "file": ".devcontainer/Dockerfile",
        "pattern": (
            r"(?P<quote>[\"']?)gotest\.tools/gotestsum@(?P<version>latest)"
            r"(?P=quote)(?=$|\s)"
        ),
        "version_source": "https://github.com/gotestyourself/gotestsum.git tags",
        "rationale": (
            "The declaration explicitly tracks latest; the report records that token "
            "without inventing a deterministic current version."
        ),
    },
    "gopls": {
        "name": "gopls",
        "classification": "pinned",
        "file": ".devcontainer/post-create.sh",
        "pattern": (
            r"^[ \t]*go[ \t]+install(?:[ \t]+|[ \t]*\\\r?\n[ \t]+)"
            r"(?P<quote>[\"']?)golang\.org/x/tools/gopls@v"
            r"(?P<version>[^\"'\s]+)(?P=quote)(?=$|\s)"
        ),
        "source": "gopls",
        "policy": {"min_inclusive": "0.21.0", "max_exclusive": "0.22.0"},
        "rationale": "Report a stable tag only within the explicitly approved 0.21 line.",
    },
    "delve": {
        "name": "delve",
        "classification": "pinned",
        "file": ".devcontainer/post-create.sh",
        "pattern": (
            r"(?P<quote>[\"']?)github\.com/go-delve/delve/cmd/dlv@v"
            r"(?P<version>[^\"'\s]+)(?P=quote)(?=$|\s)"
        ),
        "source": "delve",
        "policy": {"min_inclusive": "1.27.0", "max_exclusive": "2.0.0"},
        "rationale": (
            "Report a stable 1.x tag only; maintainers must validate debugger support."
        ),
    },
    "staticcheck": {
        "name": "staticcheck",
        "classification": "pinned",
        "file": ".devcontainer/post-create.sh",
        "pattern": (
            r"(?P<quote>[\"']?)honnef\.co/go/tools/cmd/staticcheck@v"
            r"(?P<version>[^\"'\s]+)(?P=quote)(?=$|\s)"
        ),
        "source": "staticcheck",
        "policy": {"min_inclusive": "0.7.0", "max_exclusive": "0.8.0"},
        "rationale": "Report a stable tag only within the explicitly approved 0.7 line.",
    },
    "uv": {
        "name": "uv",
        "classification": "pinned",
        "file": ".devcontainer/Dockerfile",
        "pattern": r"^ARG UV_VERSION=(?P<version>\S+)$",
        "source": "uv",
        "policy": {"min_inclusive": "0.7.0", "max_exclusive": "0.8.0"},
        "rationale": "Report a stable candidate only within the approved 0.7 line.",
    },
    "playwright": {
        "name": "playwright",
        "classification": "pinned",
        "file": ".devcontainer/Dockerfile",
        "pattern": r"npx playwright@(?P<version>\S+) install",
        "source": "playwright",
        "policy": {"min_inclusive": "1.62.0", "max_exclusive": "1.63.0"},
        "rationale": (
            "Report a stable candidate only within the approved 1.62 line; browser "
            "compatibility must be validated."
        ),
    },
    "prometheus": {
        "name": "prometheus",
        "classification": "pinned",
        "file": ".devcontainer/Dockerfile",
        "pattern": r"^ARG PROMETHEUS_VERSION=(?P<version>\S+)$",
        "source": "prometheus",
        "policy": {"min_inclusive": "3.4.0", "max_exclusive": "4.0.0"},
        "rationale": (
            "Report a stable 3.x tag only; maintainers must validate Prometheus data "
            "and flags."
        ),
    },
    "opencode-cli": {
        "name": "opencode-cli",
        "classification": "floating",
        "file": ".devcontainer/post-create.sh",
        "pattern": r"@opencode/cli@\$\{OPENCODE_VERSION:-(?P<version>latest)\}",
        "version_source": "registry.npmjs.org/@opencode/cli",
        "rationale": (
            "The default is latest and can be overridden by users; the report does not "
            "reinterpret that policy."
        ),
    },
    "postgres-service-image": {
        "name": "postgres-service-image",
        "classification": "repo-coupled",
        "file": ".devcontainer/init-services.sh",
        "pattern": r"^POSTGRES_IMAGE=(?P<version>\S+)$",
        "authority": "OpenShift CI image promotion configuration",
        "rationale": (
            "The explicit CI image tag is promotion-coupled and requires its owning "
            "authority; no independent bump is proposed."
        ),
    },
    "redis-service-image": {
        "name": "redis-service-image",
        "classification": "repo-coupled",
        "file": ".devcontainer/init-services.sh",
        "pattern": r"^REDIS_IMAGE=(?P<version>\S+)$",
        "authority": "OpenShift CI image promotion configuration",
        "rationale": (
            "The explicit CI image tag is promotion-coupled and requires its owning "
            "authority; no independent bump is proposed."
        ),
    },
    "apm-cli": {
        "name": "apm-cli",
        "classification": "pinned",
        "file": ".devcontainer/post-create.sh",
        "pattern": (
            r"(?P<quote>[\"']?)apm-cli==(?P<version>[^\"'\s]+)"
            r"(?P=quote)(?=$|\s)"
        ),
        "source": "apm-cli",
        "policy": {"min_inclusive": "0.11.0", "max_exclusive": "0.12.0"},
        "rationale": "Report a stable candidate only within the approved 0.11 line.",
    },
}

REPOSITORIES: dict[str, list[str]] = {
    "openshift/sippy": [
        "fedora-base",
        "golangci-lint",
        "github-cli",
        "gotestsum-pinned",
        "gopls",
        "delve",
        "staticcheck",
        "opencode-cli",
        "postgres-service-image",
        "redis-service-image",
        "agentic-ci",
        "codex-version",
        "codex-sha256-x86_64",
        "codex-sha256-aarch64",
        "claude-installer",
    ],
    "openshift/origin": [
        "fedora-base",
        "golangci-lint",
        "github-cli",
        "gotestsum-pinned",
        "gopls",
        "delve",
        "staticcheck",
        "opencode-cli",
        "agentic-ci",
        "codex-version",
        "codex-sha256-x86_64",
        "codex-sha256-aarch64",
        "claude-installer",
    ],
    "openshift-eng/ship-status-dash": [
        "fedora-base",
        "golangci-lint",
        "github-cli",
        "uv",
        "playwright",
        "gotestsum-floating",
        "prometheus",
        "gopls",
        "delve",
        "staticcheck",
        "opencode-cli",
        "apm-cli",
        "agentic-ci",
        "codex-version",
        "codex-sha256-x86_64",
        "codex-sha256-aarch64",
        "claude-installer",
    ],
}

REPORT_NOTES = [
    "Only actual declarations with an explicitly extracted token are inventoried.",
    (
        "Devcontainer declarations are owned by the target repository; agentic CI "
        "declarations are owned by openshift/release and use separate source provenance."
    ),
    (
        "Unversioned OS package sets, installer URLs, module graphs, lockfiles, and "
        "repository build targets remain owned by the target repository and are not "
        "represented as pseudo-version rows."
    ),
    (
        "Repository-coupled values are reported only when an explicit token exists; "
        "they never receive an independent update proposal."
    ),
    (
        "The unversioned Claude installer URL is an extracted floating declaration, "
        "not an invented version or update proposal."
    ),
]


class CheckError(RuntimeError):
    """An expected lookup, extraction, or policy failure."""


def parse_version(value: str, prefix: str = "") -> tuple[int, int, int]:
    if prefix and not value.startswith(prefix):
        raise CheckError(f"{value!r} does not start with required prefix {prefix!r}")
    candidate = value[len(prefix) :]
    match = STABLE_VERSION.fullmatch(candidate)
    if not match:
        raise CheckError(f"{value!r} is not a stable three-part version")
    try:
        return tuple(int(part) for part in match.groups())
    except ValueError as exc:
        raise CheckError(f"{value!r} has an invalid numeric component") from exc


def version_in_policy(version: tuple[int, int, int], policy: dict[str, str]) -> bool:
    return (
        parse_version(policy["min_inclusive"])
        <= version
        < parse_version(policy["max_exclusive"])
    )


def validate_repository_name(repository: str) -> None:
    if not REPOSITORY_NAME.fullmatch(repository):
        raise CheckError(f"invalid public GitHub repository name {repository!r}")


def require_string(value: Any, description: str) -> str:
    if not isinstance(value, str) or not value:
        raise CheckError(f"{description} must be a non-empty string")
    return value


def validate_relative_path(value: str, description: str) -> None:
    path = Path(value)
    if path.is_absolute() or not path.parts or ".." in path.parts:
        raise CheckError(f"{description} must be a safe relative path")


def validate_policy() -> dict[str, re.Pattern[str]]:
    for source_name, source in SOURCES.items():
        require_string(source_name, "source name")
        if not isinstance(source, dict):
            raise CheckError(f"source {source_name!r} must be an object")
        kind = source.get("kind")
        if kind == "git_tags":
            repository = require_string(
                source.get("repository"), f"source {source_name!r} repository"
            )
            validate_repository_name(repository)
            require_string(
                source.get("tag_prefix"), f"source {source_name!r} tag_prefix"
            )
        elif kind == "npm":
            package = require_string(
                source.get("package"), f"source {source_name!r} package"
            )
            if not NPM_PACKAGE.fullmatch(package):
                raise CheckError(f"source {source_name!r} has an invalid npm package")
        elif kind == "pypi":
            package = require_string(
                source.get("package"), f"source {source_name!r} package"
            )
            if not PYPI_PACKAGE.fullmatch(package):
                raise CheckError(f"source {source_name!r} has an invalid PyPI package")
        else:
            raise CheckError(f"source {source_name!r} has unsupported kind {kind!r}")

    patterns: dict[str, re.Pattern[str]] = {}
    for dependency_id, dependency in DEPENDENCIES.items():
        require_string(dependency_id, "dependency identifier")
        if not isinstance(dependency, dict):
            raise CheckError(f"dependency {dependency_id!r} must be an object")
        for field in ("name", "pattern", "rationale"):
            require_string(
                dependency.get(field), f"dependency {dependency_id!r} field {field}"
            )
        file_value = dependency.get("file")
        files_value = dependency.get("files")
        if (file_value is None) == (files_value is None):
            raise CheckError(
                f"dependency {dependency_id!r} requires exactly one of file or files"
            )
        if file_value is not None:
            file_path = require_string(
                file_value, f"dependency {dependency_id!r} field file"
            )
            validate_relative_path(file_path, f"dependency {dependency_id!r} file")
        else:
            if not isinstance(files_value, dict) or not files_value:
                raise CheckError(
                    f"dependency {dependency_id!r} files must be a non-empty mapping"
                )
            for repository, file_path_value in files_value.items():
                validate_repository_name(
                    require_string(
                        repository, f"dependency {dependency_id!r} repository"
                    )
                )
                file_path = require_string(
                    file_path_value,
                    f"dependency {dependency_id!r} file for {repository!r}",
                )
                validate_relative_path(
                    file_path, f"dependency {dependency_id!r} file for {repository!r}"
                )
        scope = dependency.get("scope", "devcontainer")
        if scope not in SCOPES:
            raise CheckError(
                f"dependency {dependency_id!r} has invalid scope {scope!r}"
            )
        source_repository = dependency.get("source_repository")
        if source_repository is not None:
            validate_repository_name(
                require_string(
                    source_repository,
                    f"dependency {dependency_id!r} source_repository",
                )
            )
        update_group = dependency.get("update_group")
        if update_group is not None:
            require_string(update_group, f"dependency {dependency_id!r} update_group")
        classification = dependency.get("classification")
        if classification not in CLASSIFICATIONS:
            raise CheckError(
                f"dependency {dependency_id!r} has invalid classification {classification!r}"
            )
        try:
            pattern = re.compile(dependency["pattern"], re.MULTILINE)
        except re.error as exc:
            raise CheckError(
                f"dependency {dependency_id!r} has invalid extraction regex: {exc}"
            ) from exc
        if "version" not in pattern.groupindex:
            raise CheckError(
                f"dependency {dependency_id!r} extraction requires a named version group"
            )
        patterns[dependency_id] = pattern
        if classification == "pinned":
            source_name = require_string(
                dependency.get("source"), f"dependency {dependency_id!r} source"
            )
            if source_name not in SOURCES:
                raise CheckError(
                    f"dependency {dependency_id!r} references unknown source {source_name!r}"
                )
            policy = dependency.get("policy")
            if not isinstance(policy, dict):
                raise CheckError(f"dependency {dependency_id!r} requires policy bounds")
            minimum = require_string(
                policy.get("min_inclusive"),
                f"dependency {dependency_id!r} minimum policy bound",
            )
            maximum = require_string(
                policy.get("max_exclusive"),
                f"dependency {dependency_id!r} maximum policy bound",
            )
            if parse_version(minimum) >= parse_version(maximum):
                raise CheckError(f"dependency {dependency_id!r} policy range is empty")
        elif "source" in dependency or "policy" in dependency:
            raise CheckError(
                f"dependency {dependency_id!r} may not define source or policy"
            )
        if classification == "repo-coupled":
            require_string(
                dependency.get("authority"), f"dependency {dependency_id!r} authority"
            )
        elif classification != "pinned":
            require_string(
                dependency.get("version_source"),
                f"dependency {dependency_id!r} version_source",
            )

    for repository, dependency_ids in REPOSITORIES.items():
        validate_repository_name(repository)
        if not isinstance(dependency_ids, list) or not dependency_ids:
            raise CheckError(f"repository {repository!r} requires dependencies")
        if not all(isinstance(item, str) for item in dependency_ids):
            raise CheckError(
                f"repository {repository!r} dependency names must be strings"
            )
        if len(dependency_ids) != len(set(dependency_ids)):
            raise CheckError(f"repository {repository!r} has duplicate dependencies")
        missing = sorted(set(dependency_ids) - set(DEPENDENCIES))
        if missing:
            raise CheckError(
                f"repository {repository!r} references unknown dependencies: "
                + ", ".join(missing)
            )
        for dependency_id in dependency_ids:
            files = DEPENDENCIES[dependency_id].get("files")
            if files is not None and repository not in files:
                raise CheckError(
                    f"dependency {dependency_id!r} has no file for {repository!r}"
                )
    return patterns


def source_url(source: dict[str, str]) -> str:
    if source["kind"] == "git_tags":
        return f"https://github.com/{source['repository']}.git"
    if source["kind"] == "npm":
        package = urllib.parse.quote(source["package"], safe="@")
        return f"https://registry.npmjs.org/{package}"
    if source["kind"] == "pypi":
        return f"https://pypi.org/pypi/{source['package']}/json"
    raise CheckError(f"unsupported source kind {source['kind']!r}")


def source_description(source: dict[str, str]) -> str:
    url = source_url(source)
    return f"{url} tags" if source["kind"] == "git_tags" else url


def validate_fixed_endpoint(url: str, expected_url: str) -> None:
    try:
        parsed = urllib.parse.urlsplit(url)
        expected = urllib.parse.urlsplit(expected_url)
        port = parsed.port
    except (TypeError, ValueError) as exc:
        raise CheckError(f"invalid package lookup URL: {exc}") from exc
    if (
        parsed.scheme != "https"
        or parsed.hostname != expected.hostname
        or parsed.path != expected.path
        or parsed.query
        or parsed.fragment
        or parsed.username is not None
        or parsed.password is not None
        or port is not None
    ):
        raise CheckError("package lookup redirected outside its fixed public endpoint")


class FixedEndpointRedirectHandler(urllib.request.HTTPRedirectHandler):
    def __init__(self, expected_url: str) -> None:
        self.expected_url = expected_url
        super().__init__()

    def redirect_request(
        self,
        req: urllib.request.Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> Optional[urllib.request.Request]:
        validate_fixed_endpoint(newurl, self.expected_url)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class Fetcher:
    def __init__(self) -> None:
        self.cache: dict[str, Any] = {}

    def get_package_json(self, source: dict[str, str]) -> dict[str, Any]:
        url = source_url(source)
        if url in self.cache:
            return self.cache[url]
        validate_fixed_endpoint(url, url)
        accept = (
            "application/vnd.npm.install-v1+json"
            if source["kind"] == "npm"
            else "application/json"
        )
        request = urllib.request.Request(
            url,
            headers={
                "Accept": accept,
                "User-Agent": "openshift-release-devcontainer-dependency-report/1",
            },
        )
        opener = urllib.request.build_opener(FixedEndpointRedirectHandler(url))
        try:
            with opener.open(request, timeout=30) as response:
                validate_fixed_endpoint(response.geturl(), url)
                body = response.read().decode("utf-8")
        except (
            OSError,
            UnicodeError,
            urllib.error.HTTPError,
            http.client.HTTPException,
        ) as exc:
            raise CheckError(
                f"package lookup failed for {source_description(source)}: {exc}"
            ) from exc
        try:
            payload = json.loads(body)
        except json.JSONDecodeError as exc:
            raise CheckError(
                f"package lookup returned invalid JSON for {source_description(source)}: {exc}"
            ) from exc
        if not isinstance(payload, dict):
            raise CheckError(
                f"package lookup returned a non-object for {source_description(source)}"
            )
        self.cache[url] = payload
        return payload


def sanitize_git_stderr(stderr: str) -> str:
    message = " ".join(stderr.splitlines())
    message = re.sub(r"(https?://)[^/@\s]+@", r"\1<redacted>@", message)
    message = re.sub(r"(ssh://)[^@\s]+@", r"\1<redacted>@", message)
    return message[-500:] or "no stderr"


def run_git(
    repository_root: Optional[Path], arguments: list[str]
) -> subprocess.CompletedProcess[str]:
    command = ["git"]
    if repository_root is not None:
        command.extend(["-C", str(repository_root)])
    command.extend(arguments)
    try:
        return subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise CheckError(f"could not run git: {exc}") from exc


def checked_git(
    repository_root: Optional[Path], arguments: list[str], operation: str
) -> str:
    completed = run_git(repository_root, arguments)
    if completed.returncode != 0:
        raise CheckError(
            f"{operation} failed (git exit {completed.returncode}): "
            f"{sanitize_git_stderr(completed.stderr)}"
        )
    return completed.stdout


def repository_from_remote(remote: str) -> Optional[str]:
    scp_match = re.fullmatch(
        r"git@github\.com:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?", remote
    )
    if scp_match:
        return scp_match.group(1)
    try:
        parsed = urllib.parse.urlsplit(remote)
        port = parsed.port
    except ValueError:
        return None
    if (
        parsed.scheme not in {"https", "ssh"}
        or parsed.hostname != "github.com"
        or parsed.query
        or parsed.fragment
        or port is not None
    ):
        return None
    if parsed.scheme == "https" and (
        parsed.username is not None or parsed.password is not None
    ):
        return None
    if parsed.scheme == "ssh" and parsed.username not in {None, "git"}:
        return None
    path = parsed.path.removeprefix("/").removesuffix(".git")
    return path if REPOSITORY_NAME.fullmatch(path) else None


def job_spec_workdir_repository() -> str:
    raw_spec = os.environ.get("JOB_SPEC")
    if not raw_spec:
        raise CheckError(
            "checkout has no public origin remote and JOB_SPEC is unavailable for identity"
        )
    try:
        spec = json.loads(raw_spec)
    except json.JSONDecodeError as exc:
        raise CheckError(f"JOB_SPEC is not valid JSON: {exc}") from exc
    if not isinstance(spec, dict):
        raise CheckError("JOB_SPEC root is not an object")
    refs: list[dict[str, Any]] = []
    primary = spec.get("refs")
    if "refs" in spec:
        if not isinstance(primary, dict):
            raise CheckError("JOB_SPEC refs is not a reference object")
        refs.append(primary)
    extra_refs = spec.get("extra_refs", [])
    if not isinstance(extra_refs, list) or not all(
        isinstance(ref, dict) for ref in extra_refs
    ):
        raise CheckError("JOB_SPEC extra_refs is not a list of reference objects")
    refs.extend(extra_refs)
    if not refs:
        raise CheckError("JOB_SPEC contains no checkout references")
    for ref in refs:
        if "workdir" in ref and not isinstance(ref["workdir"], bool):
            raise CheckError("JOB_SPEC reference workdir must be boolean")
    explicit_workdirs = [ref for ref in refs if ref.get("workdir") is True]
    if len(explicit_workdirs) > 1:
        raise CheckError("JOB_SPEC contains multiple workdir references")
    workdir_ref = explicit_workdirs[0] if explicit_workdirs else refs[0]
    org = workdir_ref.get("org")
    repo = workdir_ref.get("repo")
    if not isinstance(org, str) or not isinstance(repo, str):
        raise CheckError("JOB_SPEC workdir reference has no repository identity")
    repository = f"{org}/{repo}"
    validate_repository_name(repository)
    return repository


def validate_checkout_identity(repository: str, repository_root: Path) -> str:
    remote = run_git(repository_root, ["config", "--get", "remote.origin.url"])
    if remote.returncode == 0:
        remote_repository = repository_from_remote(remote.stdout.strip())
        if remote_repository != repository:
            raise CheckError(
                "local checkout origin does not match the selected public repository"
            )
        return "public-origin-remote"
    if remote.returncode != 1 or remote.stdout.strip() or remote.stderr.strip():
        raise CheckError(
            f"could not inspect checkout origin (git exit {remote.returncode}): "
            f"{sanitize_git_stderr(remote.stderr)}"
        )
    if repository_root != Path("/workspace"):
        raise CheckError(
            "local checkout without a public origin remote must be the CI /workspace workdir"
        )
    if job_spec_workdir_repository() != repository:
        raise CheckError("JOB_SPEC workdir does not match the selected repository")
    return "job-spec-workdir"


def local_repository_revision(repository_root: Path) -> str:
    output = checked_git(
        repository_root,
        ["rev-parse", "--show-toplevel", "HEAD"],
        "determining local checkout revision",
    ).splitlines()
    if len(output) != 2:
        raise CheckError("git returned an unexpected checkout root/revision response")
    checkout_root, revision = output
    try:
        root_matches = Path(checkout_root).resolve() == repository_root.resolve()
    except (OSError, RuntimeError) as exc:
        raise CheckError(
            f"could not validate the local Git checkout root: {exc}"
        ) from exc
    if not root_matches:
        raise CheckError("--repository-root is not the selected Git checkout root")
    if not COMMIT_SHA.fullmatch(revision):
        raise CheckError("git returned an invalid local HEAD revision")
    return revision


def local_inventory_source(
    repository_root: Path,
    file_paths: list[str],
    revision: str,
    captured_files: dict[str, Union[bytes, CheckError]],
) -> str:
    output = checked_git(
        repository_root,
        [
            "--no-optional-locks",
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            "--",
            *sorted(set(file_paths)),
        ],
        "inspecting local working tree",
    )
    dirty = bool(output)
    for file_path, captured in captured_files.items():
        if isinstance(captured, CheckError):
            dirty = True
            continue
        entry = checked_git(
            repository_root,
            ["ls-tree", "--full-tree", revision, "--", file_path],
            f"finding committed input {file_path}",
        ).strip()
        if not entry:
            dirty = True
            continue
        fields = entry.partition("\t")[0].split()
        if len(fields) != 3 or fields[1] != "blob":
            raise CheckError(f"git returned an invalid tree entry for {file_path}")
        try:
            hashed = subprocess.run(
                [
                    "git",
                    "-C",
                    str(repository_root),
                    "hash-object",
                    f"--path={file_path}",
                    "--stdin",
                ],
                input=captured,
                check=False,
                capture_output=True,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise CheckError(
                f"could not hash captured input {file_path}: {exc}"
            ) from exc
        if hashed.returncode != 0:
            raise CheckError(
                f"hashing captured input {file_path} failed (git exit "
                f"{hashed.returncode}): "
                f"{sanitize_git_stderr(hashed.stderr.decode('utf-8', errors='replace'))}"
            )
        if hashed.stdout.decode("ascii", errors="replace").strip() != fields[2]:
            dirty = True
    return "local-checkout-dirty" if dirty else "local-checkout-clean"


def git_tag_versions(source: dict[str, str]) -> list[str]:
    prefix = source["tag_prefix"]
    output = checked_git(
        None,
        [
            "ls-remote",
            "--tags",
            "--refs",
            source_url(source),
            f"refs/tags/{prefix}*",
        ],
        f"listing public tags for source {source['repository']}",
    )
    versions: list[str] = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != 2 or not fields[1].startswith("refs/tags/"):
            raise CheckError("git ls-remote returned an unexpected tag record")
        versions.append(fields[1].removeprefix("refs/tags/"))
    return versions


def source_versions(source: dict[str, str], fetcher: Fetcher) -> list[str]:
    kind = source["kind"]
    if kind == "git_tags":
        return git_tag_versions(source)
    payload = fetcher.get_package_json(source)
    if kind == "npm":
        releases = payload.get("versions")
        if not isinstance(releases, dict):
            raise CheckError("npm response has no version map")
        versions: list[str] = []
        for version, metadata in releases.items():
            if not isinstance(version, str) or not isinstance(metadata, dict):
                raise CheckError("npm version map has an invalid entry")
            if not metadata.get("deprecated"):
                versions.append(version)
        return versions
    if kind == "pypi":
        releases = payload.get("releases")
        if not isinstance(releases, dict):
            raise CheckError("PyPI response has no version map")
        versions = []
        for version, files in releases.items():
            if not isinstance(version, str) or not isinstance(files, list):
                raise CheckError("PyPI version map has an invalid entry")
            if not all(isinstance(item, dict) for item in files):
                raise CheckError("PyPI version file list has an invalid entry")
            if files and any(not item.get("yanked") for item in files):
                versions.append(version)
        return versions
    raise CheckError(f"unsupported source kind {kind!r}")


def latest_allowed(
    source: dict[str, str], policy: dict[str, str], fetcher: Fetcher
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


def selected_dependencies(repository: str) -> list[tuple[str, dict[str, Any]]]:
    validate_repository_name(repository)
    dependency_ids = REPOSITORIES.get(repository)
    if dependency_ids is None:
        raise CheckError(
            f"selected repository {repository!r} is not in embedded policy"
        )
    selected: list[tuple[str, dict[str, Any]]] = []
    for dependency_id in dependency_ids:
        dependency = dict(DEPENDENCIES[dependency_id])
        files = dependency.pop("files", None)
        if files is not None:
            dependency["file"] = files[repository]
        dependency.setdefault("scope", "devcontainer")
        dependency.setdefault("source_repository", repository)
        if dependency["source_repository"] not in {repository, "openshift/release"}:
            raise CheckError(
                f"dependency {dependency_id!r} has unsupported source repository "
                f"{dependency['source_repository']!r}"
            )
        selected.append((dependency_id, dependency))
    return selected


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
            f"repository file escapes the local checkout: {file_path!r}"
        ) from exc
    return candidate


def capture_repository_files(
    repository_root: Path, file_paths: list[str]
) -> dict[str, Union[bytes, CheckError]]:
    captured: dict[str, Union[bytes, CheckError]] = {}
    for file_path in sorted(set(file_paths)):
        try:
            captured[file_path] = repository_file(
                repository_root, file_path
            ).read_bytes()
        except (CheckError, OSError) as exc:
            captured[file_path] = CheckError(
                f"could not read local repository file {file_path}: {exc}"
            )
    return captured


def staged_release_source(
    release_source_root: Path, file_paths: list[str]
) -> tuple[str, str, str, dict[str, Union[bytes, CheckError]]]:
    try:
        revision = (
            (release_source_root / "REVISION").read_text(encoding="ascii").strip()
        )
        sums = (
            (release_source_root / "SHA256SUMS")
            .read_text(encoding="ascii")
            .splitlines()
        )
    except (OSError, UnicodeError) as exc:
        raise CheckError(
            f"could not read release source snapshot metadata: {exc}"
        ) from exc
    if not COMMIT_SHA.fullmatch(revision):
        raise CheckError("release source snapshot has an invalid revision")
    expected: dict[str, str] = {}
    for line in sums:
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            raise CheckError("release source snapshot has an invalid SHA256 record")
        digest, file_path = match.groups()
        validate_relative_path(file_path, "release source SHA256 path")
        if file_path in expected:
            raise CheckError(
                f"release source snapshot repeats SHA256 path {file_path!r}"
            )
        expected[file_path] = digest
    captured = capture_repository_files(release_source_root, file_paths)
    for file_path, content in captured.items():
        if isinstance(content, CheckError):
            continue
        digest = expected.get(file_path)
        if digest is None:
            captured[file_path] = CheckError(
                f"release source snapshot has no SHA256 for {file_path}"
            )
        elif hashlib.sha256(content).hexdigest() != digest:
            captured[file_path] = CheckError(
                f"release source snapshot SHA256 does not match {file_path}"
            )
    return (
        revision,
        "ci-operator-release-source-snapshot",
        "prow-release-ref",
        captured,
    )


def load_release_source(
    release_source_root: Path, file_paths: list[str]
) -> tuple[str, str, str, dict[str, Union[bytes, CheckError]]]:
    if not release_source_root.is_dir():
        raise CheckError(
            f"release source checkout does not exist: {release_source_root}"
        )
    git_probe = run_git(release_source_root, ["rev-parse", "--is-inside-work-tree"])
    if git_probe.returncode == 0 and git_probe.stdout.strip() == "true":
        revision = local_repository_revision(release_source_root)
        checkout_identity = validate_checkout_identity(
            "openshift/release", release_source_root
        )
        captured = capture_repository_files(release_source_root, file_paths)
        inventory_source = local_inventory_source(
            release_source_root, file_paths, revision, captured
        )
        return revision, inventory_source, checkout_identity, captured
    return staged_release_source(release_source_root, file_paths)


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


def extract_current(content: str, pattern: re.Pattern[str]) -> str:
    matches = list(pattern.finditer(content))
    if len(matches) != 1:
        raise CheckError(
            f"extraction pattern matched {len(matches)} times; exactly one match is required"
        )
    return matches[0].group("version")


def check(
    repository: str,
    dependencies: list[tuple[str, dict[str, Any]]],
    patterns: dict[str, re.Pattern[str]],
    fetcher: Fetcher,
    captured_sources: dict[str, dict[str, Union[bytes, CheckError]]],
    source_revisions: dict[str, Optional[str]],
) -> list[dict[str, Any]]:
    results: list[dict[str, Any]] = []
    file_cache: dict[str, Union[str, CheckError]] = {}
    source_cache: dict[tuple[str, str, str], tuple[str, tuple[int, int, int]]] = {}
    for dependency_id, dependency in dependencies:
        file_path = dependency["file"]
        source_repository = dependency["source_repository"]
        source_revision = source_revisions.get(source_repository)
        row: dict[str, Any] = {
            "repository": repository,
            "revision": source_revisions.get(repository),
            "scope": dependency["scope"],
            "file": file_path,
            "source_repository": source_repository,
            "source_file": file_path,
            "source_revision": source_revision,
            "owner_repository": source_repository,
            "update_group": dependency.get("update_group"),
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
            cache_key = f"{source_repository}:{file_path}"
            if cache_key not in file_cache:
                try:
                    captured = captured_sources[source_repository][file_path]
                    if isinstance(captured, CheckError):
                        raise captured
                    file_cache[cache_key] = captured.decode("utf-8")
                except (CheckError, UnicodeError) as exc:
                    file_cache[cache_key] = CheckError(
                        f"could not read {source_repository} source file {file_path}: {exc}"
                    )
            content = file_cache[cache_key]
            if isinstance(content, CheckError):
                raise content
            if source_revision is None:
                raise CheckError(
                    f"source revision is unavailable for {source_repository}"
                )
            current = extract_current(content, patterns[dependency_id])
            row["current"] = current
            if dependency["classification"] == "pinned":
                source_name = dependency["source"]
                source = SOURCES[source_name]
                row["version_source"] = source_description(source)
                current_parsed = parse_version(current)
                if not version_in_policy(current_parsed, dependency["policy"]):
                    raise CheckError(
                        "current version is outside the explicit policy range"
                    )
                version_cache_key = (
                    source_name,
                    dependency["policy"]["min_inclusive"],
                    dependency["policy"]["max_exclusive"],
                )
                if version_cache_key not in source_cache:
                    source_cache[version_cache_key] = latest_allowed(
                        source, dependency["policy"], fetcher
                    )
                proposed, proposed_parsed = source_cache[version_cache_key]
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
        except (CheckError, re.error) as exc:
            row["status"] = "error"
            row["error"] = str(exc)
        results.append(row)
    return results


def write_reports(
    results: list[dict[str, Any]],
    output_dir: Path,
    *,
    repository: str,
    repository_revision: str,
    inventory_source: str,
    checkout_identity: str,
    release_source: dict[str, Optional[str]],
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()
    document = {
        "schema_version": 2,
        "generated_at": generated_at,
        "policy": {
            "source": "embedded in openshift-devcontainer-dependency-report-commands.py",
            "schema_version": 2,
        },
        "repository": {
            "name": repository,
            "revision": repository_revision,
            "inventory_source": inventory_source,
            "checkout_identity": checkout_identity,
        },
        "release_source": release_source,
        "scope_notes": REPORT_NOTES,
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
        "# Devcontainer and agentic CI dependency report",
        "",
        f"Generated: {generated_at}",
        "",
        "Policy: embedded and co-versioned with the checker script",
        "",
        f"Repository revision: `{repository}@{repository_revision}`",
        "",
        f"Inventory source: `{inventory_source}`",
        "",
        f"Checkout identity: `{checkout_identity}`",
        "",
        (
            "Release source: `openshift/release@"
            f"{release_source.get('revision') or 'unavailable'}` "
            f"(`{release_source.get('inventory_source') or 'error'}`)"
        ),
        "",
        "This report is advisory. It does not claim compatibility or modify dependencies.",
        "",
        "## Scope notes",
        "",
        *[f"- {note}" for note in REPORT_NOTES],
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
            "| Report target | Scope | Declaration source | Dependency | Class | Current | Proposed | Status | Version source / authority | Rationale |",
            "|---|---|---|---|---|---|---|---|---|---|",
        ]
    )
    for row in results:
        values = [
            row["repository"],
            row["scope"],
            (
                f"{row['source_repository']}@"
                f"{row['source_revision'] or 'unavailable'}:{row['source_file']}"
            ),
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
        help="one public repository named in the embedded policy",
    )
    parser.add_argument(
        "--repository-root",
        default=Path("/workspace"),
        type=Path,
        help="local checkout of the selected repository (default: /workspace)",
    )
    parser.add_argument(
        "--release-source-root",
        default=Path(
            os.environ.get(
                "DEVCONTAINER_DEPENDENCY_RELEASE_SOURCE_ROOT", "/release-source"
            )
        ),
        type=Path,
        help=(
            "local openshift/release checkout or CI source snapshot "
            "(default: /release-source)"
        ),
    )
    parser.add_argument("--output-dir", default=default_output, type=Path)
    parser.add_argument(
        "--fail-on-errors", action=argparse.BooleanOptionalAction, default=True
    )
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    phase = "validating embedded policy"
    try:
        patterns = validate_policy()
        if not args.repository:
            raise CheckError(
                "--repository or DEVCONTAINER_DEPENDENCY_REPOSITORY is required"
            )
        phase = "selecting repository policy"
        dependencies = selected_dependencies(args.repository)
        target_file_paths = [
            dependency["file"]
            for _, dependency in dependencies
            if dependency["source_repository"] == args.repository
        ]
        release_file_paths = [
            dependency["file"]
            for _, dependency in dependencies
            if dependency["source_repository"] == "openshift/release"
        ]
        phase = "validating target checkout"
        if not args.repository_root.is_dir():
            raise CheckError(
                f"target repository checkout does not exist: {args.repository_root}"
            )
        revision = local_repository_revision(args.repository_root)
        checkout_identity = validate_checkout_identity(
            args.repository, args.repository_root
        )
        captured_files = capture_repository_files(
            args.repository_root, target_file_paths
        )
        inventory_source = local_inventory_source(
            args.repository_root, target_file_paths, revision, captured_files
        )
        ensure_output_outside_repository(args.output_dir, args.repository_root)
        if args.release_source_root.is_dir():
            ensure_output_outside_repository(args.output_dir, args.release_source_root)
        phase = "loading release source snapshot"
        release_error: Optional[str] = None
        try:
            (
                release_revision,
                release_inventory_source,
                release_checkout_identity,
                release_captured_files,
            ) = load_release_source(args.release_source_root, release_file_paths)
        except CheckError as exc:
            release_error = str(exc)
            release_revision = None
            release_inventory_source = None
            release_checkout_identity = None
            release_captured_files = {
                file_path: CheckError(release_error) for file_path in release_file_paths
            }
        release_source = {
            "name": "openshift/release",
            "revision": release_revision,
            "inventory_source": release_inventory_source,
            "checkout_identity": release_checkout_identity,
            "error": release_error,
        }
        phase = "checking dependency versions"
        results = check(
            args.repository,
            dependencies,
            patterns,
            Fetcher(),
            {
                args.repository: captured_files,
                "openshift/release": release_captured_files,
            },
            {
                args.repository: revision,
                "openshift/release": release_revision,
            },
        )
        phase = "writing report artifacts"
        write_reports(
            results,
            args.output_dir,
            repository=args.repository,
            repository_revision=revision,
            inventory_source=inventory_source,
            checkout_identity=checkout_identity,
            release_source=release_source,
        )
    except (OSError, CheckError) as exc:
        print(
            f"devcontainer dependency report failed during {phase}: {exc}",
            file=sys.stderr,
        )
        return 2
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
