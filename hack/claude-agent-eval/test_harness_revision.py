"""Unit tests for harness revision resolution: validation, API, and Git plumbing."""

import io
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock
import urllib.error

try:
    from . import test_manifest_runner as support
except ImportError:
    import test_manifest_runner as support


config_bridge = support.config_bridge
runner = support.runner


class RevisionValidationTests(unittest.TestCase):
    def test_release_tags_are_accepted(self):
        self.assertEqual(config_bridge.validate_harness_revision("v1.62.0"), "v1.62.0")
        self.assertEqual(config_bridge.validate_harness_revision("v1.61.5-rc.1"), "v1.61.5-rc.1")

    def test_branches_commits_and_malformed_revisions_are_rejected(self):
        for bad in ("", "main", "HEAD", "v1", "v1.2", "e4b0f24b",
                    "0123456789abcdef0123456789abcdef01234567",
                    "v1.2.3:refs/heads/evil", "refs/heads/main", "v1/2/3", "../escape"):
            with self.subTest(revision=bad):
                with self.assertRaises(config_bridge.EvalError):
                    config_bridge.validate_harness_revision(bad)

    def test_expected_commit_ref_names_the_pinned_commit(self):
        self.assertEqual(config_bridge.expected_commit_ref("v1.62.0"), "refs/tags/v1.62.0^{commit}")


class LatestReleaseTests(unittest.TestCase):
    def test_latest_release_tag_validates_the_document(self):
        self.assertEqual(config_bridge.latest_release_tag({"tag_name": "v1.62.0"}), "v1.62.0")
        for bad in ({}, {"tag_name": None}, {"tag_name": "main"},
                    {"tag_name": "v1.2.3:refs/heads/evil"}, [], "v1.2.3"):
            with self.subTest(document=bad):
                with self.assertRaises(config_bridge.EvalError):
                    config_bridge.latest_release_tag(bad)

    def test_resolve_latest_release_reads_the_api_document(self):
        body = json.dumps({"tag_name": "v1.62.0"}).encode()
        opened = []

        def urlopen(request, timeout=None):
            opened.append((request, timeout))
            return io.BytesIO(body)

        with mock.patch("urllib.request.urlopen", side_effect=urlopen):
            self.assertEqual(config_bridge.resolve_latest_release({}, 17), "v1.62.0")
        request, timeout = opened[0]
        self.assertEqual(timeout, 17)
        self.assertEqual(request.full_url, config_bridge.HARNESS_LATEST_RELEASE)
        self.assertIsNone(request.get_header("Authorization"))  # public endpoint, no token needed

    def test_resolve_latest_release_uses_the_token_when_present(self):
        captured = {}

        def urlopen(request, timeout=None):
            captured.update(dict(request.header_items()))
            captured["timeout"] = timeout
            return io.BytesIO(json.dumps({"tag_name": "v1.62.0"}).encode())

        with mock.patch("urllib.request.urlopen", side_effect=urlopen):
            self.assertEqual(config_bridge.resolve_latest_release({"GITHUB_TOKEN": "secret"}, 5),
                             "v1.62.0")
        self.assertEqual(captured["Authorization"], "Bearer secret")
        self.assertEqual(captured["timeout"], 5)

    def test_resolve_latest_release_failures_are_eval_errors(self):
        for failure in (urllib.error.URLError("dns"), TimeoutError(), ValueError("bad json")):
            with self.subTest(failure=failure):
                with mock.patch("urllib.request.urlopen", side_effect=failure):
                    with self.assertRaises(config_bridge.EvalError):
                        config_bridge.resolve_latest_release({}, 5)


class ResolveOverrideTests(unittest.TestCase):
    def test_override_pins_without_touching_the_api(self):
        with mock.patch("urllib.request.urlopen") as urlopen:
            resolved = config_bridge.resolve_harness_revision(
                {config_bridge.REVISION_OVERRIDE: " v1.61.5 "}, 5)
        self.assertEqual(resolved, ("v1.61.5", f"{config_bridge.REVISION_OVERRIDE} override"))
        urlopen.assert_not_called()

    def test_invalid_override_fails_before_any_fetch(self):
        with self.assertRaises(config_bridge.EvalError):
            config_bridge.resolve_harness_revision({config_bridge.REVISION_OVERRIDE: "main"}, 5)

    def test_absent_override_resolves_the_latest_release(self):
        document = io.BytesIO(json.dumps({"tag_name": "v1.62.0"}).encode())
        with mock.patch("urllib.request.urlopen", return_value=document):
            self.assertEqual(config_bridge.resolve_harness_revision({}, 5),
                             ("v1.62.0", "latest release"))


class PrepareHarnessTests(unittest.TestCase):
    """The resolved release tag must reach Git as an exact ref, never a branch."""

    def prepare(self, revision):
        """Run prepare_harness with mocked Git, returning its commands and log."""
        calls = []

        def command(args, *_arguments, **_keywords):  # signature matches runner.command
            calls.append(args)
            if "rev-parse" in args:
                return 0, "0123456789abcdef0123456789abcdef01234567\n" * 2
            return 0

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "runner").mkdir()
            with mock.patch.object(runner, "resolve_harness_revision",
                                   return_value=(revision, "test")), \
                    mock.patch.object(runner, "command", side_effect=command):
                runner.prepare_harness(root, {}, root / "runner", root, time.monotonic() + 300)
            log = (root / "runner" / "harness-install.log").read_text()
        return calls, log, root / "plugin"

    def test_a_release_tag_is_cloned_directly_and_verified(self):
        calls, _, harness = self.prepare("v1.62.0")
        self.assertEqual(len(calls), 2)  # one shallow clone, then one verification
        clone, verify = calls[0], calls[1]
        self.assertEqual(clone[clone.index("clone"):],
                         ["clone", "--quiet", "--depth", "1", "--branch", "v1.62.0",
                          config_bridge.HARNESS_URL, str(harness)])
        self.assertEqual(verify[-2:], ["refs/tags/v1.62.0^{commit}", "HEAD"])

    def test_the_resolved_revision_and_commit_reach_the_install_log(self):
        _, log, _ = self.prepare("v1.62.0")
        self.assertIn("Expected harness revision: v1.62.0 (test)\n", log)
        self.assertIn("Verified harness revision: 0123456789abcdef0123456789abcdef01234567\n", log)
