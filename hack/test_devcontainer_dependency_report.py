#!/usr/bin/env python3
"""Focused tests using recorded public-upstream response shapes."""

# pylint: disable=too-many-public-methods

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPONENT_DIR = (
    ROOT / "ci-operator/step-registry/openshift/devcontainer-dependency-report"
)
SPEC = importlib.util.spec_from_file_location(
    "devcontainer_dependency_report",
    COMPONENT_DIR / "openshift-devcontainer-dependency-report-commands.py",
)
assert SPEC and SPEC.loader
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def dependency(file_name: str = ".devcontainer/Dockerfile") -> dict:
    return {
        "name": "tool",
        "classification": "pinned",
        "file": file_name,
        "extract": {
            "kind": "regex",
            "pattern": r"^ARG TOOL_VERSION=(?P<version>\S+)$",
        },
        "source": "tool",
        "policy": {"min_inclusive": "1.0.0", "max_exclusive": "2.0.0"},
        "rationale": "Recorded fixture candidate; compatibility is not implied.",
    }


def config(item: dict, source_url: str = "https://example.invalid/releases") -> dict:
    return {
        "schema_version": 1,
        "sources": {
            "tool": {
                "kind": "github_releases",
                "tag_prefix": "v",
                "url": source_url,
            }
        },
        "repositories": [
            {
                "name": "example/repo",
                "ref": "main",
                "raw_base": "https://example.invalid/repo/main",
                "dependencies": [item],
            }
        ],
    }


def configured_dependency(cfg: dict, repository_name: str, dependency_name: str) -> dict:
    for repository in cfg["repositories"]:
        if repository["name"] != repository_name:
            continue
        for item in repository["dependencies"]:
            if item["name"] == dependency_name:
                return item
    raise AssertionError(f"missing configured dependency {repository_name}/{dependency_name}")


PINNED_DECLARATIONS = {
    "golangci-lint": ("ARG GOLANGCI_LINT_VERSION=", "2.15.0", "\n"),
    "github-cli": ("ARG GH_VERSION=", "2.92.0", "\n"),
    "gotestsum": ("go install gotest.tools/gotestsum@v", "1.13.0", "\n"),
    "gopls": ("go install golang.org/x/tools/gopls@v", "0.21.1", "\n"),
    "delve": ("go install github.com/go-delve/delve/cmd/dlv@v", "1.27.1", "\n"),
    "staticcheck": (
        "go install honnef.co/go/tools/cmd/staticcheck@v",
        "0.7.0",
        "\n",
    ),
    "uv": ("ARG UV_VERSION=", "0.7.13", "\n"),
    "playwright": ("RUN npx playwright@", "1.62.1", " install chromium\n"),
    "prometheus": ("ARG PROMETHEUS_VERSION=", "3.4.1", "\n"),
    "apm-cli": ("uv tool install apm-cli==", "0.11.0", "\n"),
}


def pinned_declaration(dependency_name: str, version_suffix: str = "") -> tuple[str, str]:
    prefix, stable_version, suffix = PINNED_DECLARATIONS[dependency_name]
    version = f"{stable_version}{version_suffix}"
    return f"{prefix}{version}{suffix}", version


class CheckerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.responses = json.loads(
            (
                COMPONENT_DIR
                / "openshift-devcontainer-dependency-report-recorded-responses.md"
            ).read_text(encoding="utf-8")
        )
        cls.production_config = json.loads(
            (COMPONENT_DIR / "openshift-devcontainer-dependency-report-config.md").read_text(
                encoding="utf-8"
            )
        )

    def run_check(self, cfg: dict) -> dict:
        return CHECKER.check(cfg, CHECKER.Fetcher(self.responses))[0]

    def test_extracts_and_selects_only_stable_version_inside_policy(self) -> None:
        row = self.run_check(config(dependency()))
        self.assertEqual(row["current"], "1.2.0")
        self.assertEqual(row["proposed"], "1.2.1")
        self.assertEqual(row["status"], "update_available")

    def test_github_single_page_source_stops_without_requesting_another_page(self) -> None:
        source = {
            "kind": "github_releases",
            "tag_prefix": "v",
            "url": "https://example.invalid/releases",
        }
        versions = CHECKER.source_versions(source, CHECKER.Fetcher(self.responses))
        self.assertEqual(versions, ["v1.2.1", "v2.0.0"])

    def test_github_multipage_source_aggregates_all_pages(self) -> None:
        source = {
            "kind": "github_releases",
            "tag_prefix": "v",
            "url": "https://example.invalid/multipage-releases?per_page=2",
        }
        versions = CHECKER.source_versions(source, CHECKER.Fetcher(self.responses))
        self.assertEqual(versions, ["v1.1.0", "v1.2.0", "v1.3.0"])

    def test_github_second_page_gopls_candidate_is_selected(self) -> None:
        source = {
            "kind": "github_tags",
            "tag_prefix": "gopls/v",
            "url": "https://example.invalid/gopls-tags?per_page=2",
        }
        proposed, parsed = CHECKER.latest_allowed(
            source,
            {"min_inclusive": "0.21.0", "max_exclusive": "0.22.0"},
            CHECKER.Fetcher(self.responses),
        )
        self.assertEqual((proposed, parsed), ("0.21.2", (0, 21, 2)))

    def test_github_later_page_fetch_failure_is_visible(self) -> None:
        source = {
            "kind": "github_tags",
            "tag_prefix": "v",
            "url": "https://example.invalid/page-error?per_page=2",
        }
        with self.assertRaisesRegex(CHECKER.CheckError, "recorded page-2 timeout"):
            CHECKER.source_versions(source, CHECKER.Fetcher(self.responses))

    def test_github_pagination_limit_refuses_partial_version_data(self) -> None:
        url = "https://example.invalid/bounded-tags?per_page=1"
        responses = {url: [{"name": "v1.0.0"}]}
        for page in range(2, CHECKER.GITHUB_PAGE_LIMIT + 1):
            responses[f"{url}&page={page}"] = [{"name": f"v1.0.{page - 1}"}]
        source = {"kind": "github_tags", "tag_prefix": "v", "url": url}
        with self.assertRaisesRegex(CHECKER.CheckError, "safety limit"):
            CHECKER.source_versions(source, CHECKER.Fetcher(responses))

    def test_github_pagination_rejects_credentialed_url(self) -> None:
        source = {
            "kind": "github_tags",
            "url": "https://account@example.invalid/tags",
        }
        with self.assertRaisesRegex(CHECKER.CheckError, "without credentials"):
            CHECKER.source_versions(source, CHECKER.Fetcher({}))

    def test_no_change_never_proposes_a_downgrade(self) -> None:
        row = self.run_check(config(dependency(".devcontainer/no-change")))
        self.assertEqual(row["current"], "1.2.2")
        self.assertEqual(row["proposed"], "1.2.2")
        self.assertEqual(row["status"], "no_change")

    def test_ambiguous_extraction_is_an_error_not_no_change(self) -> None:
        row = self.run_check(config(dependency(".devcontainer/duplicate")))
        self.assertEqual(row["status"], "error")
        self.assertIsNone(row["proposed"])
        self.assertIn("matched 2 times", row["error"])

    def test_missing_extraction_is_an_error_not_no_change(self) -> None:
        row = self.run_check(config(dependency(".devcontainer/missing")))
        self.assertEqual(row["status"], "error")
        self.assertIsNone(row["proposed"])
        self.assertIn("matched 0 times", row["error"])

    def test_lookup_failure_is_an_error_not_no_change(self) -> None:
        row = self.run_check(
            config(dependency(), "https://example.invalid/lookup-error")
        )
        self.assertEqual(row["status"], "error")
        self.assertIsNone(row["proposed"])
        self.assertIn("recorded upstream timeout", row["error"])

    def test_raw_file_lookup_failure_is_visible(self) -> None:
        row = self.run_check(config(dependency(".devcontainer/raw-error")))
        self.assertEqual(row["status"], "error")
        self.assertIn("recorded raw-file 404", row["error"])

    def test_numeric_semver_order_prefix_prerelease_and_range(self) -> None:
        row = self.run_check(
            config(
                dependency(".devcontainer/numeric"),
                "https://example.invalid/semver-releases",
            )
        )
        self.assertEqual(row["current"], "1.9.9")
        self.assertEqual(row["proposed"], "1.10.0")
        self.assertEqual(row["status"], "update_available")

    def test_version_prefix_is_required(self) -> None:
        with self.assertRaisesRegex(CHECKER.CheckError, "required prefix"):
            CHECKER.parse_version("1.2.3", "v")

    def test_leading_zero_version_is_not_stable_semver(self) -> None:
        with self.assertRaisesRegex(CHECKER.CheckError, "not a stable"):
            CHECKER.parse_version("1.02.3")

    def test_npm_deprecated_release_is_not_selected(self) -> None:
        source = {"kind": "npm", "url": "https://example.invalid/npm"}
        proposed, parsed = CHECKER.latest_allowed(
            source,
            {"min_inclusive": "1.0.0", "max_exclusive": "2.0.0"},
            CHECKER.Fetcher(self.responses),
        )
        self.assertEqual((proposed, parsed), ("1.2.1", (1, 2, 1)))

    def test_pypi_yanked_or_empty_release_is_not_selected(self) -> None:
        source = {"kind": "pypi", "url": "https://example.invalid/pypi"}
        proposed, parsed = CHECKER.latest_allowed(
            source,
            {"min_inclusive": "1.0.0", "max_exclusive": "2.0.0"},
            CHECKER.Fetcher(self.responses),
        )
        self.assertEqual((proposed, parsed), ("1.2.1", (1, 2, 1)))

    def test_policy_boundaries_are_inclusive_and_exclusive(self) -> None:
        policy = {"min_inclusive": "1.2.0", "max_exclusive": "2.0.0"}
        self.assertTrue(CHECKER.version_in_policy((1, 2, 0), policy))
        self.assertTrue(CHECKER.version_in_policy((1, 99, 99), policy))
        self.assertFalse(CHECKER.version_in_policy((1, 1, 99), policy))
        self.assertFalse(CHECKER.version_in_policy((2, 0, 0), policy))

    def test_prerelease_current_is_an_error(self) -> None:
        row = self.run_check(config(dependency(".devcontainer/prerelease")))
        self.assertEqual(row["status"], "error")
        self.assertIn("not a stable three-part version", row["error"])

    def test_all_pinned_extractors_capture_complete_stable_tokens(self) -> None:
        for repository in self.production_config["repositories"]:
            for item in repository["dependencies"]:
                if item["classification"] != "pinned":
                    continue
                with self.subTest(repository=repository["name"], dependency=item["name"]):
                    content, expected = pinned_declaration(item["name"])
                    current = CHECKER.extract_current(content, item)
                    self.assertEqual(current, expected)
                    self.assertEqual(CHECKER.parse_version(current), tuple(map(int, expected.split("."))))

    def test_all_pinned_extractors_do_not_truncate_prerelease_tokens(self) -> None:
        for repository in self.production_config["repositories"]:
            for item in repository["dependencies"]:
                if item["classification"] != "pinned":
                    continue
                with self.subTest(repository=repository["name"], dependency=item["name"]):
                    content, expected = pinned_declaration(item["name"], "-rc.1")
                    current = CHECKER.extract_current(content, item)
                    self.assertEqual(current, expected)
                    with self.assertRaisesRegex(CHECKER.CheckError, "not a stable"):
                        CHECKER.parse_version(current)

    def test_gopls_extractor_rejects_invalid_complete_token(self) -> None:
        item = configured_dependency(self.production_config, "openshift/sippy", "gopls")
        content, expected = pinned_declaration("gopls", ".invalid")
        current = CHECKER.extract_current(content, item)
        self.assertEqual(current, expected)
        with self.assertRaisesRegex(CHECKER.CheckError, "not a stable"):
            CHECKER.parse_version(current)

    def test_current_outside_policy_is_an_error(self) -> None:
        row = self.run_check(config(dependency(".devcontainer/outside")))
        self.assertEqual(row["status"], "error")
        self.assertIn("outside the explicit policy range", row["error"])

    def test_no_stable_version_in_range_is_an_error(self) -> None:
        row = self.run_check(
            config(
                dependency(),
                "https://example.invalid/no-stable-releases",
            )
        )
        self.assertEqual(row["status"], "error")
        self.assertIn("no stable version inside", row["error"])

    def test_non_pinned_declaration_remains_visible_without_lookup(self) -> None:
        item = {
            "name": "tool",
            "classification": "floating",
            "file": ".devcontainer/floating",
            "extract": {
                "kind": "regex",
                "pattern": r"^ARG TOOL_VERSION=(?P<version>latest)$",
            },
            "version_source": "https://example.invalid/project",
            "rationale": "The declaration is intentionally floating.",
        }
        row = self.run_check(config(item))
        self.assertEqual(row["current"], "latest")
        self.assertIsNone(row["proposed"])
        self.assertEqual(row["status"], "floating")

    def test_all_non_pinned_classes_have_no_proposal(self) -> None:
        for classification in ("floating", "manual", "unsupported"):
            with self.subTest(classification=classification):
                item = {
                    "name": "tool",
                    "classification": classification,
                    "file": ".devcontainer/floating",
                    "extract": {
                        "kind": "regex",
                        "pattern": r"^ARG TOOL_VERSION=(?P<version>latest)$",
                    },
                    "version_source": "https://example.invalid/project",
                    "rationale": "No automatic proposal is valid.",
                }
                row = self.run_check(config(item))
                self.assertEqual(row["status"], classification)
                self.assertIsNone(row["proposed"])

    def test_repo_coupled_authority_is_the_version_source(self) -> None:
        item = {
            "name": "tool",
            "classification": "repo-coupled",
            "file": ".devcontainer/coupled",
            "extract": {
                "kind": "regex",
                "pattern": r"^ARG TOOL_VERSION=(?P<version>repository-lock)$",
            },
            "authority": "the repository lockfile",
            "rationale": "The repository owns this selection.",
        }
        row = self.run_check(config(item))
        self.assertEqual(row["status"], "repo-coupled")
        self.assertEqual(row["version_source"], "the repository lockfile")
        self.assertIsNone(row["proposed"])

    def test_repo_coupled_entry_requires_authority(self) -> None:
        item = {
            "name": "tool",
            "classification": "repo-coupled",
            "file": ".devcontainer/coupled",
            "extract": {
                "kind": "regex",
                "pattern": r"^ARG TOOL_VERSION=(?P<version>repository-lock)$",
            },
            "rationale": "The repository owns this selection.",
        }
        with self.assertRaisesRegex(CHECKER.CheckError, "require authority"):
            CHECKER.check(config(item), CHECKER.Fetcher(self.responses))

    def test_policy_range_must_be_non_empty(self) -> None:
        item = dependency()
        item["policy"] = {"min_inclusive": "2.0.0", "max_exclusive": "1.0.0"}
        with self.assertRaisesRegex(CHECKER.CheckError, "range must be non-empty"):
            CHECKER.check(config(item), CHECKER.Fetcher(self.responses))

    def test_policy_requires_both_bounds(self) -> None:
        item = dependency()
        item["policy"] = {"min_inclusive": "1.0.0"}
        with self.assertRaisesRegex(CHECKER.CheckError, "require policy bounds"):
            CHECKER.check(config(item), CHECKER.Fetcher(self.responses))

    def test_duplicate_dependency_declaration_is_rejected(self) -> None:
        cfg = config(dependency())
        cfg["repositories"][0]["dependencies"].append(dependency())
        with self.assertRaisesRegex(CHECKER.CheckError, "duplicate dependency"):
            CHECKER.check(cfg, CHECKER.Fetcher(self.responses))

    def test_writes_json_and_markdown_artifacts(self) -> None:
        row = self.run_check(config(dependency()))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            CHECKER.write_reports([row], output)
            self.assertTrue((output / "devcontainer-dependency-report.json").is_file())
            markdown = (output / "devcontainer-dependency-report.md").read_text(
                encoding="utf-8"
            )
            self.assertIn("example/repo", markdown)
            self.assertIn("compatibility", markdown)


if __name__ == "__main__":
    unittest.main()
