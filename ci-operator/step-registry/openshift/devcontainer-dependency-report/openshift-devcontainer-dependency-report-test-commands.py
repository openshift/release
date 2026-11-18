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

    def test_lookup_failure_is_an_error_not_no_change(self) -> None:
        row = self.run_check(
            config(dependency(), "https://example.invalid/lookup-error")
        )
        self.assertEqual(row["status"], "error")
        self.assertIsNone(row["proposed"])
        self.assertIn("recorded upstream timeout", row["error"])

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
