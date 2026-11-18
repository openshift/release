#!/usr/bin/env python3
"""Focused tests using recorded public-upstream response shapes."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "devcontainer_dependency_report",
    HERE / "openshift-devcontainer-dependency-report-commands.py",
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


class CheckerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.responses = json.loads(
            (HERE / "openshift-devcontainer-dependency-report-recorded-responses.md").read_text(
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
