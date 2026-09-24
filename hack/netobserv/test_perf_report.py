#!/usr/bin/env python3
"""Run with: python3 hack/netobserv/test_perf_report.py"""

import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError
from urllib.parse import parse_qs, unquote, urlparse


ROOT = Path(__file__).resolve().parents[2]
COMMANDS = ROOT / "ci-operator/step-registry/netobserv/perf-test/report/netobserv-perf-test-report-commands.sh"
GENERATOR = compile(COMMANDS.read_text().split("<<'PYTHON_NETOBSERV_REPORT'\n", 1)[1]
                    .split("\nPYTHON_NETOBSERV_REPORT", 1)[0], str(COMMANDS), "exec")


class NetobservReportTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.artifacts = self.root / "artifacts"
        self.shared = self.root / "shared"
        self.shared.mkdir()
        self.env = {
            "ARTIFACT_DIR": str(self.artifacts), "SHARED_DIR": str(self.shared),
            "RUN_ORION": "true", "JOB_NAME": "periodic-netobserv", "BUILD_ID": "123",
            "JOB_NAME_SAFE": "density", "JOB_TYPE": "periodic",
            "ORION_CONFIG": "https://example.test/config.yaml",
            "LOOKBACK": "30", "LOOKBACK_SIZE": "15", "VERSION": "5.0",
        }
        self.identity()
        self.rows = [
            {"uuid": "current-uuid", "timestamp": 1750000000, "ocpVersion": "5.0",
             "metrics": {"cpu": {"value": 1.25, "is_changepoint": False}}},
            {"uuid": "newer-history", "timestamp": 1750100000,
             "metrics": {"cpu": {"value": 99, "is_changepoint": True, "percentage_change": 20}}},
        ]
        self.files = {
            "finished.json": {"passed": False, "timestamp": 1750200000},
            "artifacts/output_test.json": self.rows,
            "artifacts/output_test_viz.html": "<html>Graph</html>",
        }
        self.requests = []

    def identity(self, build="123"):
        (self.shared / "orion-current-run.json").write_text(json.dumps({
            "uuid": "current-uuid", "build_id": build, "workload": "node-density-heavy",
        }))

    def fetch(self, url, timeout):
        self.requests.append(url)
        parsed = urlparse(url)
        self.assertEqual(parsed.scheme, "https")
        self.assertEqual(parsed.hostname, "storage.googleapis.com")
        self.assertEqual(timeout, 20)
        if parsed.path.startswith("/storage/v1/"):
            prefix = parse_qs(parsed.query)["prefix"][0]
            value = {"items": [{"name": prefix + name} for name in self.files]}
        else:
            key = unquote(parsed.path).split("/openshift-qe-orion/", 1)[1]
            value = self.files[key]
        raw = value if isinstance(value, str) else json.dumps(value)
        return io.BytesIO(raw.encode())

    def render(self, fetch=None):
        with patch.dict(os.environ, self.env, clear=True), \
                patch("urllib.request.urlopen", side_effect=fetch or self.fetch), \
                patch("time.sleep"):
            exec(GENERATOR, {"__name__": "__main__"})
        return (self.artifacts / "custom-link-orion.html").read_text()

    def test_exact_uuid_match_and_historical_scope(self):
        report = self.render()
        current, history = report.split("<h2>Historical context</h2>")
        self.assertIn("Current sample: test", current)
        self.assertIn("<td>1.25</td>", current)
        self.assertNotIn("<td>99</td>", current)
        self.assertIn("Orion step failed", current)
        self.assertIn("newer-history", history)
        self.assertIn("Historical sample", history)
        self.assertIn("2 analyzed samples", history)
        self.assertIn('data-src="https://gcs.ci.openshift.org/gcs/test-platform-results-public/logs/periodic-netobserv/123/artifacts/density/openshift-qe-orion/artifacts/output_test_viz.html"', report)
        self.assertNotIn('<iframe src=', report)
        self.assertFalse(any(url.endswith("_viz.html") for url in self.requests))

    def test_missing_and_stale_identity_do_not_guess_latest_sample(self):
        for build in ("other-build", ""):
            self.identity(build)
            report = self.render()
            self.assertIn("Current-run identity unavailable", report)
            self.assertNotIn("Current sample:", report)
        (self.shared / "orion-current-run.json").unlink()
        self.assertIn("Current-run identity unavailable", self.render())

    def test_current_run_absent_from_analysis(self):
        self.files["artifacts/output_test.json"] = self.rows[1:]
        report = self.render()
        self.assertIn("This run is not present", report)
        self.assertNotIn("Current sample:", report)
        self.assertIn("Show historical graphs", report)

    def test_current_changepoint_missing_value_and_escaping(self):
        self.rows[0]["metrics"] = {'<script>alert("x")</script>': {
            "value": float("nan"), "is_changepoint": True, "percentage_change": -25,
        }}
        report = self.render()
        self.assertIn("&lt;script&gt;", report)
        self.assertNotIn('<script>alert("x")', report)
        self.assertIn("Unavailable", report)
        self.assertIn("Change point at this sample", report)
        self.assertIn("<td>This run</td>", report)

    def test_presubmit_links_use_job_spec_for_rehearsals(self):
        self.env.update(JOB_TYPE="presubmit", JOB_NAME="rehearse-job", PULL_NUMBER="999",
                        REPO_OWNER="netobserv", REPO_NAME="netobserv-perf-tests",
                        JOB_SPEC=json.dumps({"refs": {"org": "openshift", "repo": "release",
                                                     "pulls": [{"number": 1234}]}}))
        self.files['artifacts/output space&.json'] = []
        report = self.render()
        self.assertIn("pr-logs/pull/openshift_release/1234/rehearse-job/123/", report)
        self.assertNotIn("pr-logs/pull/netobserv_netobserv-perf-tests/999", report)
        self.assertIn("output%20space%26.json", report)

    def test_no_results_and_skipped_analysis(self):
        self.files = {"finished.json": {"passed": True, "timestamp": 1750200000}}
        report = self.render()
        self.assertIn("Orion step passed", report)
        self.assertIn("No structured analysis results available", report)
        self.assertIn("No historical graph artifacts available", report)
        self.files = {}
        report = self.render()
        self.assertIn("step skipped or artifacts not yet available", report)
        self.assertNotIn("Orion step passed", report)

    def test_malformed_results_do_not_hide_valid_results(self):
        self.files["artifacts/output_broken.json"] = "[broken"
        self.files["artifacts/output_other.json"] = {"not": "samples"}
        report = self.render()
        self.assertIn("Current sample: test", report)
        self.assertIn("Could not read output_broken.json", report)
        self.assertIn("does not contain an Orion sample list", report)

    def test_storage_failure_still_produces_report(self):
        def fail(url, timeout):
            raise URLError("storage unavailable")
        report = self.render(fetch=fail)
        self.assertIn("Could not read Orion artifacts", report)
        self.assertIn("step skipped or artifacts not yet available", report)
        self.assertIn("Step log", report)

    def test_public_mirror_delay_is_retried(self):
        attempts = 0

        def delayed(url, timeout):
            nonlocal attempts
            if "/storage/v1/" in url:
                attempts += 1
                if attempts == 1:
                    return io.BytesIO(b'{"items": []}')
            return self.fetch(url, timeout)

        report = self.render(fetch=delayed)
        self.assertEqual(attempts, 2)
        self.assertIn("Current sample: test", report)

    def test_paginated_artifact_listing(self):
        def paginated(url, timeout):
            if "/storage/v1/" not in url:
                return self.fetch(url, timeout)
            query = parse_qs(urlparse(url).query)
            prefix = query["prefix"][0]
            if "pageToken" not in query:
                return io.BytesIO(json.dumps({"items": [{"name": prefix + "finished.json"}],
                                              "nextPageToken": "page2"}).encode())
            self.assertEqual(query["pageToken"], ["page2"])
            return io.BytesIO(json.dumps({"items": [{"name": prefix + name}
                                                    for name in self.files if name != "finished.json"]}).encode())

        report = self.render(fetch=paginated)
        self.assertIn("Current sample: test", report)
        self.assertIn("Show historical graphs", report)


if __name__ == "__main__":
    unittest.main()
