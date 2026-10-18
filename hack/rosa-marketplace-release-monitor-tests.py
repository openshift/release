#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DETECTOR = ROOT / "ci-operator/step-registry/rosa/marketplace/release/detect/rosa-marketplace-release-detect-commands.sh"
PUBLISHER = ROOT / "ci-operator/step-registry/rosa/marketplace/release/publish/rosa-marketplace-release-publish-commands.sh"

CURL_MOCK = """#!/usr/bin/env python3
import os
import pathlib
import sys

arguments = sys.argv[1:]
pathlib.Path(os.environ["TEST_CURL_ARGS"]).write_text("\\n".join(arguments))
counter = pathlib.Path(os.environ["TEST_CURL_COUNT"])
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
destination = pathlib.Path(arguments[arguments.index("--output") + 1])
if attempt <= int(os.environ.get("TEST_CURL_FAILURES", "0")):
    destination.write_text(os.environ.get("TEST_CURL_PARTIAL", ""))
    sys.stdout.write("000")
    raise SystemExit(7)
destination.write_text(os.environ.get("TEST_ACCEPTED", "{}"))
if attempt <= int(os.environ.get("TEST_HTTP_FAILURES", "0")):
    sys.stdout.write(os.environ.get("TEST_FAILURE_HTTP_CODE", "503"))
else:
    sys.stdout.write(os.environ.get("TEST_HTTP_CODE", "200"))
"""

OCM_MOCK = """#!/usr/bin/env python3
import json
import os
import pathlib
import re
import sys
import time

arguments = sys.argv[1:]
with pathlib.Path(os.environ["TEST_OCM_CALLS"]).open("a") as log:
    log.write(json.dumps(arguments) + "\\n")
if arguments[0] == "login":
    raise SystemExit(int(os.environ.get("TEST_OCM_LOGIN_EXIT", "0")))
if arguments[0] != "get":
    raise SystemExit(2)
counter = pathlib.Path(os.environ["TEST_OCM_GET_COUNT"])
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
if attempt <= int(os.environ.get("TEST_OCM_FAILURES", "0")):
    sys.stdout.write(os.environ.get("TEST_OCM_PARTIAL", ""))
    raise SystemExit(8)
time.sleep(float(os.environ.get("TEST_OCM_DELAY", "0")))
search = next((value for value in arguments if value.startswith("search=")), "")
match = re.search(r"raw_id like '(\\d+\\.\\d+)\\.%" + "'", search)
if not match:
    raise SystemExit(3)
responses = json.loads(os.environ.get("TEST_OCM_RESPONSES", "{}"))
response = responses.get(match.group(1), {"items": [], "total": 0})
sys.stdout.write(response if isinstance(response, str) else json.dumps(response))
"""

SLEEP_MOCK = """#!/usr/bin/env python3
import os
import pathlib
import sys

with pathlib.Path(os.environ["TEST_SLEEP_ARGS"]).open("a") as log:
    log.write(" ".join(sys.argv[1:]) + "\\n")
"""


class MarketplaceMonitorTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="rosa-marketplace-test-")
        self.addCleanup(temporary.cleanup)
        self.case = Path(temporary.name)
        self.shared = self.case / "shared"
        self.scratch = self.case / "tmp"
        self.credentials = self.case / "credentials"
        for directory in (self.shared, self.scratch, self.credentials):
            directory.mkdir()
        (self.credentials / "sso-client-id").write_text("test-client-id\n")
        (self.credentials / "sso-client-secret").write_text("test-client-secret\n")
        (self.credentials / "ocm-token").write_text("test-offline-token\n")
        self.curl = self.write_mock("mock-curl", CURL_MOCK)
        self.ocm = self.write_mock("mock-ocm", OCM_MOCK)
        self.sleep = self.write_mock("mock-sleep", SLEEP_MOCK)

    def write_mock(self, name, source):
        path = self.case / name
        path.write_text(source)
        path.chmod(0o755)
        return path

    def accepted(self, **streams):
        return json.dumps(streams)

    def response(self, present_version):
        return {
            "items": [{"raw_id": present_version + ".3"}] if present_version else [],
            "total": 1 if present_version else 0,
        }

    def detector(self, **overrides):
        env = os.environ.copy()
        env.update(
            RELEASE_CONTROLLER_API="https://release-controller.example.test",
            RELEASE_CONTROLLER_RETRIES="3",
            RELEASE_CONTROLLER_RETRY_DELAY_SECONDS="2",
            RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS="3",
            RELEASE_CONTROLLER_MAX_RESPONSE_BYTES="10485760",
            OCM_REQUEST_TIMEOUT_SECONDS="5",
            OCM_RETRIES="3",
            OCM_RETRY_DELAY_SECONDS="2",
            OCM_LOGIN_ENV="production",
            ROSA_CREDENTIALS_DIR=str(self.credentials),
            SHARED_DIR=str(self.shared),
            TMPDIR=str(self.scratch),
            CURL_BIN=str(self.curl),
            OCM_BIN=str(self.ocm),
            PYTHON_BIN=sys.executable,
            SLEEP_BIN=str(self.sleep),
            TEST_CURL_ARGS=str(self.case / "curl-args"),
            TEST_CURL_COUNT=str(self.case / "curl-count"),
            TEST_OCM_CALLS=str(self.case / "ocm-calls"),
            TEST_OCM_GET_COUNT=str(self.case / "ocm-get-count"),
            TEST_SLEEP_ARGS=str(self.case / "sleep-args"),
            TEST_ACCEPTED=self.accepted(**{"5.10.0-0.nightly": ["accepted"]}),
            TEST_OCM_RESPONSES="{}",
        )
        env.update({key: str(value) for key, value in overrides.items()})
        return subprocess.run([str(DETECTOR)], env=env, text=True, capture_output=True)

    def publisher(self, **overrides):
        return subprocess.run(
            [str(PUBLISHER)],
            env=self.publisher_env(**overrides),
            text=True,
            capture_output=True,
        )

    def publisher_env(self, **overrides):
        env = os.environ.copy()
        env.update(
            SHARED_DIR=str(self.shared),
            MARKETPLACE_ENVIRONMENT="staging",
            MARKETPLACE_DRY_RUN="true",
        )
        env.update({key: str(value) for key, value in overrides.items()})
        return env

    def assert_handoff(self, state=None, version=None):
        state_file = self.shared / "rosa-marketplace-release-state"
        version_file = self.shared / "rosa-marketplace-ocp-version"
        self.assertEqual(state_file.read_text().strip() if state_file.exists() else None, state)
        self.assertEqual(version_file.read_text().strip() if version_file.exists() else None, version)
        self.assertEqual(
            sorted(path.name for path in self.shared.iterdir()),
            sorted(
                (["rosa-marketplace-release-state"] if state is not None else [])
                + (["rosa-marketplace-ocp-version"] if version is not None else [])
            ),
        )
        self.assertEqual(list(self.scratch.glob("rosa-marketplace-release-detect.*")), [])

    def ocm_calls(self):
        path = self.case / "ocm-calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def write_ready_handoff(self, version="5.10"):
        (self.shared / "rosa-marketplace-release-state").write_text("ready\n")
        (self.shared / "rosa-marketplace-ocp-version").write_text(version + "\n")

    def test_accepted_request_and_private_handoff(self):
        result = self.detector()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_handoff("ready", "5.10")
        arguments = (self.case / "curl-args").read_text().splitlines()
        self.assertIn("https://release-controller.example.test/api/v1/releasestreams/accepted", arguments)
        self.assertIn("--proto-redir", arguments)
        self.assertIn("=https", arguments)
        self.assertNotIn("test-client-secret", result.stdout + result.stderr)
        self.assertNotIn("accepted", (self.shared / "rosa-marketplace-ocp-version").read_text())

    def test_invalid_detector_settings_fail_before_requests(self):
        settings = [
            {"RELEASE_CONTROLLER_API": "http://release-controller.example.test"},
            {"RELEASE_CONTROLLER_API": "https://user@release-controller.example.test"},
            {"RELEASE_CONTROLLER_API": "https://release-controller.example.test?token=x"},
            {"RELEASE_CONTROLLER_RETRIES": "0"},
            {"RELEASE_CONTROLLER_RETRY_DELAY_SECONDS": "-1"},
            {"RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS": "0"},
            {"RELEASE_CONTROLLER_MAX_RESPONSE_BYTES": "0"},
            {"OCM_REQUEST_TIMEOUT_SECONDS": "0"},
            {"OCM_RETRIES": "0"},
            {"OCM_RETRY_DELAY_SECONDS": "-1"},
            {"OCM_LOGIN_ENV": "invalid"},
            {"CURL_BIN": str(self.case / "missing-curl")},
        ]
        for override in settings:
            with self.subTest(setting=override):
                result = self.detector(**override)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.case / "curl-count").exists())
                self.assert_handoff()

    def test_http_retry_backoff_and_partial_response(self):
        result = self.detector(
            TEST_CURL_FAILURES=1,
            TEST_CURL_PARTIAL="not-json",
            TEST_HTTP_FAILURES=2,
            RELEASE_CONTROLLER_RETRIES=4,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.case / "curl-count").read_text(), "3")
        self.assertEqual((self.case / "sleep-args").read_text().splitlines(), ["2", "3"])
        self.assert_handoff("ready", "5.10")

    def test_http_failure_and_oversized_body_fail_closed(self):
        result = self.detector(
            TEST_HTTP_FAILURES=9,
            TEST_FAILURE_HTTP_CODE=404,
            RELEASE_CONTROLLER_RETRIES=2,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.case / "curl-count").read_text(), "2")
        self.assert_handoff()

        result = self.detector(
            RELEASE_CONTROLLER_MAX_RESPONSE_BYTES=10,
            RELEASE_CONTROLLER_RETRIES=1,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assert_handoff()

    def test_invalid_accepted_response_fails_closed(self):
        invalid = [
            "[]",
            "not-json",
            '{"5.10.0-0.nightly":null}',
            '{"5.10.0-0.nightly":["tag",5]}',
            '{"5.10.0-0.nightly":[{}]}',
            '{"5.10.0-0.nightly":["tag"]} trailing',
        ]
        for body in invalid:
            with self.subTest(body=body):
                result = self.detector(TEST_ACCEPTED=body)
                self.assertNotEqual(result.returncode, 0)
                self.assert_handoff()

    def test_accepted_streams_select_newest_missing_version(self):
        accepted = self.accepted(
            **{
                "5.9.0-0.nightly": ["accepted"],
                "5.10.0-0.nightly": ["accepted"],
                "5.11.0-0.nightly": ["accepted"],
                "6.0.0-0.ci": ["ignored"],
            }
        )
        responses = {"5.11": self.response("5.11")}
        result = self.detector(TEST_ACCEPTED=accepted, TEST_OCM_RESPONSES=json.dumps(responses))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_handoff("ready", "5.10")
        self.assertIn("5.10 5.9", result.stdout)
        calls = [call for call in self.ocm_calls() if call[0] == "get"]
        self.assertEqual(len(calls), 3)
        self.assertIn("raw_id like '5.11.%'", " ".join(calls[0]))
        self.assertIn("raw_id like '5.10.%'", " ".join(calls[1]))
        self.assertIn("raw_id like '5.9.%'", " ".join(calls[2]))

    def test_older_missing_stream_is_reported_when_latest_is_current(self):
        accepted = self.accepted(
            **{"5.9.0-0.nightly": ["accepted"], "5.10.0-0.nightly": ["accepted"]}
        )
        responses = {"5.10": self.response("5.10")}
        result = self.detector(TEST_ACCEPTED=accepted, TEST_OCM_RESPONSES=json.dumps(responses))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_handoff("ready", "5.9")

    def test_wait_states_have_no_version(self):
        result = self.detector(TEST_ACCEPTED=self.accepted(**{"5.10.0-0.nightly": []}))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_handoff("wait:ocp-release-unavailable")
        self.assertEqual(self.ocm_calls(), [])

        responses = {"5.10": self.response("5.10")}
        result = self.detector(TEST_OCM_RESPONSES=json.dumps(responses))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_handoff("wait:rosa-release-current")

    def test_ocm_authentication_and_filtered_lookup(self):
        result = self.detector(
            TEST_OCM_RESPONSES=json.dumps({"5.10": {"items": [{"raw_id": "5.10.7"}], "total": 2}})
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_handoff("wait:rosa-release-current")
        login, lookup = self.ocm_calls()
        self.assertEqual(login[0], "login")
        self.assertIn("test-client-id", login)
        self.assertIn("test-client-secret", login)
        self.assertNotIn("test-offline-token", login)
        self.assertEqual(lookup[1], "/api/clusters_mgmt/v1/versions")
        self.assertIn("search=rosa_enabled = 'true' AND raw_id like '5.10.%'", lookup)
        self.assertIn("page=1", lookup)
        self.assertIn("size=1", lookup)
        self.assertNotIn("test-client-secret", result.stdout + result.stderr)

    def test_ocm_offline_fallback_and_missing_credentials(self):
        (self.credentials / "sso-client-secret").unlink()
        result = self.detector()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("test-offline-token", self.ocm_calls()[0])

        (self.credentials / "ocm-token").unlink()
        result = self.detector()
        self.assertNotEqual(result.returncode, 0)
        self.assert_handoff()

    def test_ocm_failures_retry_and_do_not_expose_partial_json(self):
        result = self.detector(TEST_OCM_FAILURES=1, TEST_OCM_PARTIAL="private-ocm-partial")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.case / "ocm-get-count").read_text(), "2")
        self.assertEqual((self.case / "sleep-args").read_text().splitlines(), ["2"])
        self.assertNotIn("private-ocm-partial", result.stdout + result.stderr)
        self.assert_handoff("ready", "5.10")

        result = self.detector(TEST_OCM_FAILURES=9, OCM_RETRIES=2)
        self.assertNotEqual(result.returncode, 0)
        self.assert_handoff()

    def test_malformed_ocm_results_fail_closed(self):
        invalid = [
            {"items": []},
            {"items": None, "total": 0},
            {"items": [{"raw_id": "5.10.3"}], "total": 0},
            {"items": [], "total": 1},
            {"items": [{"raw_id": "5.9.3"}], "total": 1},
            {"items": [None], "total": 1},
            {"items": [], "total": True},
        ]
        for response in invalid:
            with self.subTest(response=response):
                result = self.detector(TEST_OCM_RESPONSES=json.dumps({"5.10": response}))
                self.assertNotEqual(result.returncode, 0)
                self.assert_handoff()

        accepted = self.accepted(
            **{"5.10.0-0.nightly": ["accepted"], "5.9.0-0.nightly": ["accepted"]}
        )
        result = self.detector(
            TEST_ACCEPTED=accepted,
            TEST_OCM_RESPONSES=json.dumps({"5.9": {"items": [], "total": 1}}),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assert_handoff()

    def test_ocm_response_size_is_bounded(self):
        response = {"items": [], "total": 0, "padding": "x" * 200}
        result = self.detector(
            RELEASE_CONTROLLER_MAX_RESPONSE_BYTES=100,
            TEST_OCM_RESPONSES=json.dumps({"5.10": response}),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assert_handoff()

    def test_ocm_login_failure_and_query_timeout_fail_closed(self):
        result = self.detector(TEST_OCM_LOGIN_EXIT=9)
        self.assertNotEqual(result.returncode, 0)
        self.assert_handoff()

        result = self.detector(
            TEST_OCM_DELAY=2,
            OCM_REQUEST_TIMEOUT_SECONDS=1,
            OCM_RETRIES=2,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assert_handoff()

    def test_ocm_login_environments(self):
        for environment in ("production", "staging", "integration"):
            with self.subTest(environment=environment):
                result = self.detector(OCM_LOGIN_ENV=environment)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(environment, self.ocm_calls()[-2])
                self.assert_handoff("ready", "5.10")

    def test_stale_handoff_is_cleared_on_failure_and_run_recovers(self):
        self.write_ready_handoff("5.8")
        failure = self.detector(TEST_CURL_FAILURES=9, RELEASE_CONTROLLER_RETRIES=1)
        self.assertNotEqual(failure.returncode, 0)
        self.assert_handoff()

        recovered = self.detector()
        self.assertEqual(recovered.returncode, 0, recovered.stdout + recovered.stderr)
        self.assert_handoff("ready", "5.10")

    def test_stale_handoff_is_cleared_before_settings_validation(self):
        self.write_ready_handoff("5.8")
        result = self.detector(RELEASE_CONTROLLER_RETRIES=0)
        self.assertNotEqual(result.returncode, 0)
        self.assert_handoff()

    def test_publisher_preview_and_wait_states(self):
        self.write_ready_handoff()
        marker = self.write_mock(
            "forbidden-generator",
            "#!/bin/sh\nprintf invoked > \"$TEST_GENERATOR_MARKER\"\n",
        )
        result = self.publisher(
            MARKETPLACE_GENERATOR_BIN=marker,
            TEST_GENERATOR_MARKER=self.case / "generator-invoked",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Dry-run preview: would release ocp_version=5.10", result.stdout)
        self.assertFalse((self.case / "generator-invoked").exists())

        for state in ("wait:ocp-release-unavailable", "wait:rosa-release-current"):
            with self.subTest(state=state):
                (self.shared / "rosa-marketplace-release-state").write_text(state + "\n")
                (self.shared / "rosa-marketplace-ocp-version").unlink(missing_ok=True)
                result = self.publisher()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("No action", result.stdout)

    def test_publisher_rejects_live_mode_bad_state_and_bad_version(self):
        self.write_ready_handoff()
        for settings in (
            {"MARKETPLACE_DRY_RUN": "false"},
            {"MARKETPLACE_DRY_RUN": "no"},
            {"MARKETPLACE_ENVIRONMENT": "production"},
        ):
            with self.subTest(settings=settings):
                result = self.publisher(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Dry-run preview", result.stdout)

        for state in ("", "ready ", "complete", "ready\nwait:rosa-release-current"):
            with self.subTest(state=state):
                (self.shared / "rosa-marketplace-release-state").write_text(state)
                result = self.publisher()
                self.assertNotEqual(result.returncode, 0)

        (self.shared / "rosa-marketplace-release-state").write_text("ready\n")
        for version in ("", "5", "5.10.1", " 5.10", "5.10\n5.11"):
            with self.subTest(version=version):
                (self.shared / "rosa-marketplace-ocp-version").write_text(version)
                result = self.publisher()
                self.assertNotEqual(result.returncode, 0)

    def test_overlapping_periodics_remain_previews(self):
        self.write_ready_handoff()
        other_shared = self.case / "other-job-shared"
        other_shared.mkdir()
        (other_shared / "rosa-marketplace-release-state").write_text("ready\n")
        (other_shared / "rosa-marketplace-ocp-version").write_text("5.10\n")
        marker = self.write_mock(
            "forbidden-generator",
            "#!/bin/sh\nprintf invoked > \"$TEST_GENERATOR_MARKER\"\n",
        )
        processes = [
            subprocess.Popen(
                [str(PUBLISHER)],
                env=self.publisher_env(
                    SHARED_DIR=shared,
                    MARKETPLACE_GENERATOR_BIN=marker,
                    TEST_GENERATOR_MARKER=self.case / "generator-invoked",
                ),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            for shared in (self.shared, other_shared)
        ]
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, stdout + stderr)
            self.assertIn("Dry-run preview", stdout)
        self.assertFalse((self.case / "generator-invoked").exists())

    def test_ci_wiring_and_rehearsal_safety(self):
        source = (ROOT / "ci-operator/config/openshift/release/openshift-release-main.yaml").read_text()
        periodic = (
            ROOT
            / "ci-operator/config/openshift-online/rosa-marketplace-release-generator/"
            "openshift-online-rosa-marketplace-release-generator-main__rosa-marketplace-release.yaml"
        ).read_text()
        detector_ref = (
            ROOT
            / "ci-operator/step-registry/rosa/marketplace/release/detect/"
            "rosa-marketplace-release-detect-ref.yaml"
        ).read_text()
        publisher_ref = (
            ROOT
            / "ci-operator/step-registry/rosa/marketplace/release/publish/"
            "rosa-marketplace-release-publish-ref.yaml"
        ).read_text()
        generated_periodic = (
            ROOT
            / "ci-operator/jobs/openshift-online/rosa-marketplace-release-generator/"
            "openshift-online-rosa-marketplace-release-generator-main-periodics.yaml"
        ).read_text()
        generated_presubmits = (
            ROOT / "ci-operator/jobs/openshift/release/openshift-release-main-presubmits.yaml"
        ).read_text()

        self.assertIn("python3 hack/rosa-marketplace-release-monitor-tests.py", source)
        self.assertIn(
            "name: pull-ci-openshift-release-main-rosa-marketplace-release-monitor-test",
            generated_presubmits,
        )
        self.assertIn("run_if_changed: ^(hack/rosa-marketplace-release-monitor-tests", generated_presubmits)
        self.assertIn("interval: 4h", periodic)
        self.assertIn('MARKETPLACE_DRY_RUN: "true"', periodic)
        self.assertIn("OCM_LOGIN_ENV: production", periodic)
        self.assertLess(
            periodic.index("ref: rosa-marketplace-release-detect"),
            periodic.index("ref: rosa-marketplace-release-publish"),
        )
        self.assertIn("from: rosa-aws-cli", detector_ref)
        self.assertIn("bundle: cluster-secrets-rosa-e2e-01", detector_ref)
        self.assertIn("mount_path: /etc/rosa-credentials", detector_ref)
        self.assertIn("from: rosa-aws-cli", publisher_ref)
        self.assertIn('pj-rehearse.openshift.io/can-be-rehearsed: "true"', generated_periodic)


if __name__ == "__main__":
    unittest.main(verbosity=2)
